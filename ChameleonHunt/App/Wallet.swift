//
//  Wallet.swift
//  The player's coins and skins, kept on this device.
//
//  Coins come from finding chameleons (Core/Coins.swift) and go on skins
//  (Core/ChameleonSkin.swift). There's nothing to buy with money and nothing leaves the
//  device: it's a few values in UserDefaults.
//

import SwiftUI

@MainActor
final class Wallet: ObservableObject {

    static let shared = Wallet()

    @Published private(set) var coins: Int
    @Published private(set) var owned: Set<ChameleonSkin>
    /// The skin being worn.
    @Published private(set) var skin: ChameleonSkin

    private let defaults = UserDefaults.standard

    private init() {
        coins = max(0, defaults.integer(forKey: "coins"))
        let saved = (defaults.stringArray(forKey: "ownedSkins") ?? []).compactMap(ChameleonSkin.init(rawValue:))
        owned = Set(saved).union([.classic])
        let worn = defaults.string(forKey: "skin").flatMap(ChameleonSkin.init(rawValue:)) ?? .classic
        skin = saved.contains(worn) || worn == .classic ? worn : .classic
        #if DEBUG
        // `-debugCoins <n>` for screenshots (not saved); `-debugSkin <name>` to wear one.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-debugCoins"), i + 1 < args.count, let amount = Int(args[i + 1]) { coins = amount }
        if let i = args.firstIndex(of: "-debugSkin"), i + 1 < args.count, let debugSkin = ChameleonSkin(rawValue: args[i + 1]) {
            owned.insert(debugSkin)
            skin = debugSkin
        }
        #endif
    }

    func earn(_ amount: Int) {
        guard amount > 0 else { return }
        coins += amount
        defaults.set(coins, forKey: "coins")
    }

    func owns(_ skin: ChameleonSkin) -> Bool { owned.contains(skin) }
    func canAfford(_ skin: ChameleonSkin) -> Bool { coins >= skin.price }

    /// Buys a skin and puts it on. False if it's already owned or there aren't the coins.
    @discardableResult
    func buy(_ skin: ChameleonSkin) -> Bool {
        guard !owns(skin), canAfford(skin) else { return false }
        coins -= skin.price
        owned.insert(skin)
        defaults.set(coins, forKey: "coins")
        defaults.set(owned.map(\.rawValue).sorted(), forKey: "ownedSkins")
        wear(skin)
        return true
    }

    func wear(_ skin: ChameleonSkin) {
        guard owns(skin), skin != self.skin else { return }
        self.skin = skin
        defaults.set(skin.rawValue, forKey: "skin")
    }
}
