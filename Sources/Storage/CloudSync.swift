import Foundation
import Security

/// Mirrors a whitelist of UserDefaults keys to iCloud KVS.
///
/// KVS carries no metadata, so every value is wrapped in an envelope
/// `{"v": value, "t": unix-seconds}` and conflicts resolve last-writer-wins.
/// Per-key shadow keys (`cloudsync.t.<key>`) remember the timestamp of the
/// local copy. If the app is signed without the iCloud entitlement (dev builds
/// before the provisioning profile exists), sync silently stays off.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    private let kvs = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private weak var settings: SettingsStore?
    private var lastKnownLocal: [String: Any] = [:]
    private(set) var isAvailable = false

    static let syncedKeys: [String] = [
        SettingsStore.Keys.firstLanguage,
        SettingsStore.Keys.secondLanguage,
        SettingsStore.Keys.engineProfiles,
        SettingsStore.Keys.ocrLanguages,
        SettingsStore.Keys.ocrMergesLines,
        SettingsStore.Keys.ocrProvider,
        SettingsStore.Keys.ocrVisionLevel,
        // KeyboardShortcuts persists to these; applied on next launch.
        "KeyboardShortcuts_translateSelection",
        "KeyboardShortcuts_openInputWindow",
        "KeyboardShortcuts_ocrTranslate",
        "KeyboardShortcuts_ocrToInput",
    ]

    static var hasKVSEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.ubiquity-kvstore-identifier" as CFString,
            nil
        )
        return value != nil
    }

    static var hasKeychainGroupsEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
        return value != nil
    }

    func start(settings: SettingsStore) {
        self.settings = settings
        isAvailable = Self.hasKVSEntitlement
        guard isAvailable else {
            Log.sync.info("iCloud KVS entitlement absent; sync disabled")
            return
        }

        for key in Self.syncedKeys {
            lastKnownLocal[key] = defaults.object(forKey: key)
        }

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            Task { @MainActor [weak self] in
                self?.applyRemote(keys: keys ?? CloudSync.syncedKeys)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pushChangedKeys()
            }
        }

        kvs.synchronize()
        applyRemote(keys: Self.syncedKeys)
        pushChangedKeys(force: true)
    }

    // MARK: - Local → cloud

    private func pushChangedKeys(force: Bool = false) {
        guard isAvailable else { return }
        for key in Self.syncedKeys {
            let current = defaults.object(forKey: key)
            let known = lastKnownLocal[key]
            if !force, isEqual(current, known) { continue }
            lastKnownLocal[key] = current
            push(key: key, value: current, onlyIfMissingRemotely: force)
        }
    }

    private func push(key: String, value: Any?, onlyIfMissingRemotely: Bool = false) {
        if onlyIfMissingRemotely, kvs.object(forKey: key) != nil { return }
        guard let value else {
            kvs.removeObject(forKey: key)
            return
        }
        let now = Date().timeIntervalSince1970
        kvs.set(["v": value, "t": now], forKey: key)
        defaults.set(now, forKey: shadowTimeKey(key))
    }

    // MARK: - Cloud → local

    private func applyRemote(keys: [String]) {
        guard isAvailable else { return }
        var applied = false
        for key in keys where Self.syncedKeys.contains(key) {
            guard let envelope = kvs.dictionary(forKey: key),
                  let remoteTime = envelope["t"] as? Double,
                  let remoteValue = envelope["v"] else { continue }
            let localTime = defaults.double(forKey: shadowTimeKey(key))
            guard remoteTime > localTime else { continue }
            guard !isEqual(remoteValue, defaults.object(forKey: key)) else {
                defaults.set(remoteTime, forKey: shadowTimeKey(key))
                continue
            }
            defaults.set(remoteValue, forKey: key)
            defaults.set(remoteTime, forKey: shadowTimeKey(key))
            lastKnownLocal[key] = remoteValue
            applied = true
            Log.sync.info("Applied remote value for \(key, privacy: .public)")
        }
        if applied {
            settings?.reloadFromDefaults()
        }
    }

    // MARK: - Helpers

    private func shadowTimeKey(_ key: String) -> String {
        "cloudsync.t." + key
    }

    private func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case (let a?, let b?):
            return (a as? NSObject)?.isEqual(b) ?? false
        default:
            return false
        }
    }
}
