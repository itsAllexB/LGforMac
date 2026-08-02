import Foundation

/// Constant SSAP URIs and the standard webOS registration ("hello") payload.
/// The manifest mirrors the well-known one used by lgtv2 / PyWebOSTV / bscpylgtv;
/// it requests the permission set that includes reading and writing settings.
enum SsapPayloads {
    // Reading settings is allowed directly over SSAP.
    static let getSystemSettings = "ssap://settings/getSystemSettings"

    // Writing picture settings (backlight/OLED Light) is blocked for unprivileged SSAP
    // clients on stock TVs. The proven workaround (bscpylgtv/ColorControl) is to run the
    // privileged luna call indirectly via the notification-alert API: create an alert whose
    // button/onclose invokes the luna URI, then close it to fire it.
    static let createAlert = "ssap://system.notifications/createAlert"
    static let closeAlert = "ssap://system.notifications/closeAlert"
    static let lunaSetSystemSettings = "com.webos.settingsservice/setSystemSettings"

    // Power: full power-off, and "screen off" (panel blanked, webOS keeps running so the
    // picture returns instantly). The tvpower service is current firmware; tv.power is the
    // pre-2018 name, kept as a fallback.
    static let turnOff = "ssap://system/turnOff"

    // Network interface info incl. MAC addresses — the reliable way to learn the MAC for
    // Wake-on-LAN (macOS local-network privacy can hide the ARP table from us).
    static let getConnectionInfo = "ssap://com.webos.service.connectionmanager/getinfo"

    // Reports "Active", "Screen Off", "Suspend" or "Power Off". Doubles as a liveness probe:
    // a reply proves the socket is alive, silence proves it isn't.
    static let getPowerState = "ssap://com.webos.service.tvpower/power/getPowerState"
    static let turnOffScreen = "ssap://com.webos.service.tvpower/power/turnOffScreen"
    static let turnOnScreen = "ssap://com.webos.service.tvpower/power/turnOnScreen"
    static let turnOffScreenLegacy = "ssap://com.webos.service.tv.power/power/turnOffScreen"
    static let turnOnScreenLegacy = "ssap://com.webos.service.tv.power/power/turnOnScreen"

    /// Builds the registration payload. When a stored client-key is supplied the TV
    /// re-authorizes silently; otherwise it shows the on-screen accept prompt.
    static func registerPayload(clientKey: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": [
                "manifestVersion": 1,
                "appVersion": "1.1",
                "signed": [
                    "created": "20140509",
                    "appId": "com.lge.test",
                    "vendorId": "com.lge",
                    "localizedAppNames": [
                        "": "LG Remote App",
                        "ko-KR": "리모컨 앱",
                        "zxx-XX": "ЛГ Rэмotэ AПП"
                    ],
                    "localizedVendorNames": ["": "LG Electronics"],
                    "permissions": [
                        "TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD",
                        "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_NOTIFICATIONS",
                        "SEARCH", "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT",
                        "CONTROL_POWER", "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS",
                        "READ_UPDATE_INFO", "UPDATE_FROM_REMOTE_APP",
                        "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME"
                    ],
                    "serial": "2f930e2d2cfe083771f68e4fe7bb07"
                ],
                "permissions": [
                    "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE",
                    "TEST_OPEN", "TEST_PROTECTED", "CONTROL_AUDIO",
                    "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
                    "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK",
                    "CONTROL_INPUT_TV", "CONTROL_POWER", "READ_APP_STATUS",
                    "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST",
                    "READ_NETWORK_STATE", "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST",
                    "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE",
                    "READ_COUNTRY_INFO", "READ_SETTINGS", "CONTROL_TV_SCREEN",
                    "CONTROL_TV_STANBY", "CONTROL_FAVORITE_GROUP",
                    "CONTROL_USER_INFO", "CHECK_BLUETOOTH_DEVICE",
                    "CONTROL_BLUETOOTH", "CONTROL_TIMER_INFO", "STB_INTERNAL_CONNECTION",
                    "CONTROL_RECORDING", "READ_RECORDING_STATE", "WRITE_RECORDING_LIST",
                    "READ_RECORDING_LIST", "READ_RECORDING_SCHEDULE",
                    "WRITE_RECORDING_SCHEDULE", "READ_STORAGE_DEVICE_LIST",
                    "READ_TV_PROGRAM_INFO", "CONTROL_BOX_CHANNEL",
                    "READ_TV_ACR_AUTH_TOKEN", "READ_TV_CONTENT_STATE",
                    "READ_TV_CURRENT_TIME", "ADD_LAUNCHER_CHANNEL",
                    "SET_CHANNEL_SKIP", "DELETE_SELECT_CHANNEL",
                    "CONTROL_CHANNEL_GROUP", "SCAN_TV_CHANNELS",
                    "CONTROL_TV_POWER", "CONTROL_WOL"
                ],
                "signatures": [
                    [
                        "signatureVersion": 1,
                        "signature": "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQ=="
                    ]
                ]
            ]
        ]

        if let key = clientKey, !key.isEmpty {
            payload["client-key"] = key
        }
        return payload
    }
}
