import XCTest
@testable import STSSetupCore

final class ConfigFileTests: XCTestCase {
    let client = SetupValues(hubHost: "hubmac", hubUser: "dan", hubPath: "/Users/dan/star-traders-sync-hub")
    let hub = SetupValues(hubHost: "hubmac", hubUser: "dan", hubPath: "/Users/dan/star-traders-sync-hub",
                          backupVolume: "/Volumes/T9")

    func testRenderHasEveryRequiredKey() {
        let c = ConfigFile.parse(ConfigFile.render(client, examplePath: "/x/config.example"))
        for k in ["HUB_HOST", "HUB_USER", "HUB_PATH", "LOCAL_SAVE_PATH", "STEAM_APPID",
                  "GAME_PROCESS_NAME", "BACKUP_VOLUME", "BACKUP_DEST"] {
            XCTAssertFalse(c[k, default: ""].isEmpty, "\(k) missing")
        }
        XCTAssertEqual(c["HUB_HOST"], "hubmac")
        XCTAssertEqual(c["STEAM_APPID"], "335620")
    }

    /// doctor fails any value matching its placeholder patterns (#53).
    /// The app must never write one itself.
    func testRenderNeverWritesADoctorPlaceholder() {
        for v in [client, hub] {
            let c = ConfigFile.parse(ConfigFile.render(v, examplePath: "/x"))
            for k in ["HUB_HOST", "HUB_USER", "HUB_PATH", "BACKUP_VOLUME", "BACKUP_DEST"] {
                let val = c[k]!
                for bad in ["my-mac-mini", "my-macbook", "youruser", "YourDisk", "tailnet-name"] {
                    XCTAssertFalse(val.contains(bad), "\(k)=\(val)")
                }
                XCTAssertFalse(val.hasPrefix("/Volumes/Backup"), "\(k)=\(val)")
            }
        }
    }

    func testBackupDestLivesUnderVolume() {
        for v in [client, hub] {
            let c = ConfigFile.parse(ConfigFile.render(v, examplePath: "/x"))
            XCTAssertTrue(c["BACKUP_DEST"]!.hasPrefix(c["BACKUP_VOLUME"]! + "/"))
        }
    }

    func testUpdateKeepsCommentsOrderAndTunables() {
        let old = """
        # my notes
        HUB_HOST=oldhub
        HUB_USER=olduser
        HUB_PATH=/Users/olduser/hub
        LOCAL_SAVE_PATH=~/Library/StarTradersFrontiers
        SNAPSHOT_KEEP=25
        BACKUP_VOLUME=/Volumes/T9
        BACKUP_DEST=/Volumes/T9/Backups/star-traders-sync
        STEAM_APPID=335620
        GAME_PROCESS_NAME=StarTradersFrontiers

        """
        let new = ConfigFile.update(old, with: hub)
        let lines = new.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "# my notes")
        XCTAssertEqual(lines[1], "HUB_HOST=hubmac")
        XCTAssertTrue(new.contains("SNAPSHOT_KEEP=25"))
        XCTAssertFalse(new.contains("added by"), "nothing was missing, nothing should be appended")
        XCTAssertEqual(ConfigFile.update(new, with: hub), new, "update must be idempotent")
    }

    func testUpdateAppendsMissingRequiredKeys() {
        let new = ConfigFile.update("HUB_HOST=x\n", with: client)
        let c = ConfigFile.parse(new)
        XCTAssertEqual(c["HUB_HOST"], "hubmac")
        XCTAssertEqual(c["GAME_PROCESS_NAME"], "StarTradersFrontiers")
        XCTAssertEqual(c["BACKUP_VOLUME"], ConfigFile.noBackupVolume)
        XCTAssertNil(c["SYNC_EXCLUDE"], "optional keys the user left out stay out")
    }

    func testValuesRoundTripAndHideNoBackupSentinel() {
        XCTAssertEqual(ConfigFile.values(from: ConfigFile.render(client, examplePath: "/x")), client)
        XCTAssertEqual(ConfigFile.values(from: ConfigFile.render(hub, examplePath: "/x")), hub)
    }

    /// Re-running the app on a hub must never switch off a working
    /// backup because the disk's name looked like a placeholder.
    func testRealBackupDiskIsNeverDroppedOnPrefill() {
        for vol in ["/Volumes/Backup", "/Volumes/BackupDrive", "/Volumes/Backup-SSD", "/Volumes/T9"] {
            let text = "HUB_HOST=h\nHUB_USER=u\nHUB_PATH=/Users/u/hub\nBACKUP_VOLUME=\(vol)\nBACKUP_DEST=\(vol)/b\n"
            let v = ConfigFile.values(from: text)
            XCTAssertEqual(v?.backupVolume, vol)
            // And writing those values back keeps the volume.
            XCTAssertEqual(ConfigFile.parse(ConfigFile.update(text, with: v!))["BACKUP_VOLUME"], vol)
        }
    }

    func testProblemsMirrorTheScriptsValidator() {
        func problems(_ path: String, user: String = "dan", vol: String? = nil) -> [String] {
            ConfigFile.problems(SetupValues(hubHost: "h", hubUser: user, hubPath: path, backupVolume: vol),
                                localSavePath: "~/Library/StarTradersFrontiers", home: "/Users/dan")
        }
        XCTAssertEqual(problems("/Users/dan/star-traders-sync-hub"), [])
        XCTAssertFalse(problems("star-traders-sync-hub").isEmpty, "relative")
        XCTAssertFalse(problems("/Users/dan/my hub").isEmpty, "space")
        XCTAssertFalse(problems("/Users/dan/Library/StarTradersFrontiers").isEmpty, "same as save dir")
        XCTAssertFalse(problems("/Users/dan/Library/StarTradersFrontiers/").isEmpty, "trailing slash")
        XCTAssertFalse(problems("/Users/dan/Library").isEmpty, "save dir inside hub")
        XCTAssertFalse(problems("/Users/dan/Library/StarTradersFrontiers/hub").isEmpty, "hub inside save dir")
        XCTAssertEqual(problems("/Users/dan/Library/StarTradersFrontiersHub"), [], "prefix is not nesting")
        XCTAssertFalse(problems("/x", user: "dan smith").isEmpty)

        // A trailing slash on a ~/ save path is the same folder, and must
        // get the "same folder" message, not the nesting one.
        let same = ConfigFile.problems(
            SetupValues(hubHost: "h", hubUser: "dan", hubPath: "/Users/dan/Library/StarTradersFrontiers"),
            localSavePath: "~/Library/StarTradersFrontiers/", home: "/Users/dan")
        XCTAssertEqual(same, ["The hub folder cannot be the game's own save folder."])

        // A customised save folder is checked, not the default one.
        let custom = SetupValues(hubHost: "h", hubUser: "dan", hubPath: "/Volumes/Games/hub")
        XCTAssertFalse(ConfigFile.problems(custom, localSavePath: "/Volumes/Games/hub/saves",
                                           home: "/Users/dan").isEmpty)
        XCTAssertEqual(ConfigFile.problems(custom, localSavePath: "~/Library/StarTradersFrontiers",
                                           home: "/Users/dan"), [])
        XCTAssertFalse(problems("/x", vol: "/Volumes/My Disk").isEmpty)
    }
}
