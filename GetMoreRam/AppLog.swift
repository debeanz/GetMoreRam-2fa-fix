//
//  AppLog.swift
//  GetMoreRam
//
//  Sends everything the app and its libraries print (SideSign, AnisetteKit)
//  to Documents/GetMoreRam.log so it can be shared from Settings or the
//  Files app when sign-in fails.
//

import Foundation
import UIKit

enum AppLog {
    static let url = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GetMoreRam.log")

    private static let maxSize = 2_000_000

    static func start() {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxSize {
            try? FileManager.default.removeItem(at: url)
        }

        freopen(url.path, "a", stdout)
        freopen(url.path, "a", stderr)
        // Line-buffer so the file is complete when it's shared.
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        let info = Bundle.main.infoDictionary
        print("==== GetMoreRam \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) launched \(Date()) on iOS \(UIDevice.current.systemVersion) ====")
    }

    static func clear() {
        fflush(nil)
        try? Data().write(to: url)
    }
}
