//
//  StudioInputHandler.swift
//  Touch routing for the studio. Two arrangements:
//
//   - Finger painting (the default): a finger on the chameleon paints; a finger dragged
//     anywhere else turns the view, as do two fingers; pinch zooms. This is how 3D paint
//     apps (Nomad, Procreate's 3D mode) behave. It used to be that one finger always
//     painted and only two turned the view, so in testing people thought the view was
//     stuck: nothing moved until they'd painted, and then it did.
//   - Pencil painting: the Pencil paints; one finger turns, two pan, pinch zooms. It's
//     on from the start when the iPad is set to "Only Draw with Apple Pencil", and
//     otherwise switches over by itself the first time a Pencil touches the screen, so
//     a palm resting on the glass can't leave paint behind.
//
//  Two-finger tap undoes and three-finger tap redoes in both, as in Procreate.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
final class StudioInputHandler: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

    private weak var controller: StudioController?
    private var orbitGesture: UIPanGestureRecognizer?
    private var panGesture: UIPanGestureRecognizer?
    private var recenterGesture: UITapGestureRecognizer?
    private var strokeGesture: PencilStrokeRecognizer?
    private var lastPanTranslation: CGPoint = .zero
    private var lastTwoFingerTranslation: CGPoint = .zero

    func install(on view: UIView, controller: StudioController) {
        self.controller = controller
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        orbit.allowedTouchTypes = direct
        orbit.delegate = self
        view.addGestureRecognizer(orbit)
        orbitGesture = orbit

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = direct
        pan.delegate = self
        view.addGestureRecognizer(pan)
        panGesture = pan

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = direct
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let recenter = UITapGestureRecognizer(target: self, action: #selector(handleRecenter(_:)))
        recenter.numberOfTapsRequired = 2
        recenter.allowedTouchTypes = direct
        view.addGestureRecognizer(recenter)
        recenterGesture = recenter

        // Two fingers to undo, three to redo. Straight out of Procreate — anyone who has
        // drawn on an iPad already has these in their hands, and they save a trip to the
        // corner of the screen in the middle of a stroke.
        let undo = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap(_:)))
        undo.numberOfTouchesRequired = 2
        undo.allowedTouchTypes = direct
        undo.delegate = self
        view.addGestureRecognizer(undo)

        let redo = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap(_:)))
        redo.numberOfTouchesRequired = 3
        redo.allowedTouchTypes = direct
        redo.delegate = self
        view.addGestureRecognizer(redo)

        let stroke = PencilStrokeRecognizer()
        stroke.onBegan = { [weak self] point, pressure, isPencil in
            if isPencil { self?.controller?.notePencil() }
            self?.controller?.beginStroke(at: point, pressure: pressure)
        }
        stroke.onMoved = { [weak self] samples in self?.controller?.continueStroke(at: samples) }
        stroke.onEnded = { [weak self] in self?.controller?.endStroke() }
        stroke.onAborted = { [weak self] in self?.controller?.abortStroke() }
        // A finger only paints when it lands on the chameleon; elsewhere it turns the view.
        stroke.shouldBegin = { [weak self] point in self?.controller?.fingerStartsStroke(at: point) ?? true }
        view.addGestureRecognizer(stroke)
        strokeGesture = stroke
        setFingerPaints(controller.fingerPaints)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)
    }

    func setFingerPaints(_ on: Bool) {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        strokeGesture?.allowedTouchTypes = on ? [pencil, direct] : [pencil]
        // One finger turns the view either way (with finger painting, only when it didn't
        // land on the chameleon — the stroke recognizer steps aside then); with finger
        // painting two fingers turn it as well.
        orbitGesture?.minimumNumberOfTouches = 1
        orbitGesture?.maximumNumberOfTouches = on ? 2 : 1
        panGesture?.isEnabled = !on
        recenterGesture?.isEnabled = !on
    }

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: gesture.view)
        if gesture.state == .began { lastPanTranslation = .zero }
        let dx = Float(translation.x - lastPanTranslation.x)
        let dy = Float(translation.y - lastPanTranslation.y)
        lastPanTranslation = translation
        controller?.orbit(dx: dx, dy: dy)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: gesture.view)
        if gesture.state == .began { lastTwoFingerTranslation = .zero }
        let dx = Float(translation.x - lastTwoFingerTranslation.x)
        let dy = Float(translation.y - lastTwoFingerTranslation.y)
        lastTwoFingerTranslation = translation
        controller?.pan(dx: dx, dy: dy)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else { return }
        controller?.zoom(by: Float(gesture.scale))
        gesture.scale = 1
    }

    @objc private func handleUndoTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        controller?.undo()
    }

    @objc private func handleRedoTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        controller?.redo()
    }

    @objc private func handleRecenter(_ gesture: UITapGestureRecognizer) {
        controller?.resetCamera()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and two-finger pan together feel like a trackpad.
        (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        controller?.toggleEyedropper()
    }
}

/// Continuous Pencil strokes with coalesced (up to 240 Hz) samples and pressure.
final class PencilStrokeRecognizer: UIGestureRecognizer {

    var onBegan: ((CGPoint, Float, Bool) -> Void)?
    var onMoved: (([(CGPoint, Float)]) -> Void)?
    var onEnded: (() -> Void)?
    /// A finger stroke that turned into a two-finger gesture: undo what it painted.
    var onAborted: (() -> Void)?
    /// Asked when a finger (not the Pencil) lands; false lets it go to the other gestures.
    var shouldBegin: ((CGPoint) -> Bool)?

    private var trackedTouch: UITouch?
    private var startedAt: TimeInterval = 0

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
    }

    private func pressure(_ touch: UITouch) -> Float {
        // Fingers report no meaningful force; paint them at full strength.
        guard touch.type == .pencil else { return 1 }
        return touch.maximumPossibleForce > 0 ? Float(touch.force / touch.maximumPossibleForce) : 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked = trackedTouch {
            // A second finger shortly after the first: this was never a stroke, it was
            // the start of a turn or a pinch. Take back the dab it left.
            if tracked.type == .direct, event.timestamp - startedAt < 0.35 {
                trackedTouch = nil
                onAborted?()
                // Already began, so it can only be cancelled, not failed.
                state = .cancelled
            }
            return
        }
        guard let touch = touches.first, (event.allTouches?.count ?? 1) == 1 || touch.type == .pencil else {
            state = .failed
            return
        }
        if touch.type != .pencil, shouldBegin?(touch.location(in: view)) == false {
            state = .failed
            return
        }
        trackedTouch = touch
        startedAt = event.timestamp
        state = .began
        onBegan?(touch.location(in: view), pressure(touch), touch.type == .pencil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        onMoved?(samples.map { ($0.location(in: view), pressure($0)) })
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        trackedTouch = nil
        onEnded?()
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        trackedTouch = nil
        onEnded?()
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }
}
