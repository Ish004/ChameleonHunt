//
//  ChameleonHuntApp.swift
//  ChameleonHunt — pass-and-play AR hide-and-seek for LiDAR iPads.
//
//  Player 1 hides a blobby white character on a real floor or wall, scans the
//  spot, then paints the character in a 3D studio using colors from the scan
//  until it vanishes. Player 2 gets the iPad and a countdown to find it.
//

import SwiftUI

@main
struct ChameleonHuntApp: App {
    init() {
        Hunt.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-debugSideways") {
                // A phone on its side, drawn turned inside an upright one: for checking the
                // sideways layouts in a Simulator that can't be rotated from the command line.
                RootView()
                    .preferredColorScheme(.dark)
                    // As a phone on its side reports itself: short.
                    .environment(\.verticalSizeClass, .compact)
                    .frame(width: 874, height: 402)
                    .clipped()
                    .rotationEffect(.degrees(90))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else {
                RootView()
                    .preferredColorScheme(.dark)
                    .persistentSystemOverlays(.hidden)
            }
            #else
            RootView()
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
            #endif
        }
    }
}

struct RootView: View {
    @StateObject private var store = GameStore()
    /// Which RealityKit view is actually in the window right now — including while one is
    /// still fading out. Two at once breaks RealityKit's rendering (the studio came up
    /// black after the crossfade between painting and the camera), so each waits for the
    /// other to have gone completely.
    @State private var cameraMounted = false
    @State private var studioMounted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Hunt.stageBottom.ignoresSafeArea()

            // Only one RealityKit view is ever in the window: the live AR view in AR
            // phases, the studio's virtual view in the studio. The ARSession (and the
            // hide anchor) belong to the session object, not the view, so tracking
            // carries on while the AR view is unmounted.
            if showsCamera && !studioMounted {
                ARViewContainer(controller: store.ar)
                    .ignoresSafeArea()
                    .onAppear { cameraMounted = true }
                    .onDisappear { cameraMounted = false }
            }

            phaseView
                .transition(.opacity)
        }
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.25), value: store.phase)
        // Every question the game asks, in its own style (UI/Notice.swift).
        .notice($store.notice)
        .environment(\.showNotice) { [store] notice in store.notice = notice }
        .onAppear {
            Sound.shared.prepare()
            #if DEBUG
            store.applyDebugArguments()
            #endif
        }
        // No auto-lock once a game's going: a seeker scanning the room without touching
        // the screen used to get locked out after 30 seconds on an iPhone, which stops
        // the camera and, in a squad, drops them from the game.
        .onChange(of: store.phase, initial: true) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase != .intro
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.appWentAway() }
            if phase == .active, store.phase == .squad { store.squad.appBecameActive() }
        }
    }

    private var showsCamera: Bool {
        switch store.phase {
        // The handoff screen covers the camera, but the AR view stays mounted under it
        // so tracking never pauses while the iPad changes hands.
        case .placing, .scanning, .arCheck, .scattering, .handoff, .seeking, .seekerWon, .hiderWon: return true
        default: return false
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch store.phase {
        case .intro:
            IntroView(store: store)
        case .placing:
            PlacementHUD(store: store, ar: store.ar)
        case .scanning:
            ScanHUD(store: store, ar: store.ar)
        case .processing:
            ProcessingView(message: store.processingMessage, progress: store.processingProgress)
        case .studio:
            if let studio = store.studio {
                StudioView(studio: studio, isDemo: studio.scene.isDemo, showsViewport: !cameraMounted,
                           onPlaceInAR: store.placeInAR,
                           onExit: store.exitToIntro)
                    .onAppear { studioMounted = true }
                    .onDisappear { studioMounted = false }
            }
        case .arCheck:
            ARCheckHUD(store: store, ar: store.ar, presenter: store.ar.presenter)
        case .scattering:
            ScatterHUD(store: store, ar: store.ar, scatter: store.ar.scatter)
        case .handoff:
            HandoffView(store: store, onStart: store.startHunt, onBack: store.backFromHandoff)
        case .seeking:
            HuntHUD(store: store, ar: store.ar)
        case .seekerWon, .hiderWon:
            ResultView(store: store, ar: store.ar, presenter: store.ar.presenter)
        case .squad:
            // Squad play mounts its own AR view when it needs the camera.
            SquadView(store: store, squad: store.squad, ar: store.ar)
        }
    }
}

