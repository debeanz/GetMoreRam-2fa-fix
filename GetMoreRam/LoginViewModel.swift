//
//  LoginViewModel.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
import StosSign_API
import StosSign_Auth
import StosSign_Common
import class SideSign.DeveloperPortal
import enum SideSign.TwoFactorRequest
import enum SideSign.TwoFactorResponse
import enum SideSign.ServerError
import struct SideSign.AuthSession

@MainActor
class LoginViewModel: ObservableObject {
    @Published var appleID = ""
    @Published var password = ""
    @Published var needVerificationCode = false
    @Published var verificationCode = ""
    @Published var loginModalShow = false
    @Published var teamSelectionShow = false
    @Published var isLoginInProgress = false
    @Published private(set) var isVerificationCodeSubmitting = false
    @Published var logs = ""
    @Published var availableTeams: [Team] = []
    @Published private(set) var canRequestSMSCode = false

    private enum VerificationInput {
        case code(String)
        case requestSMS
    }

    private var verificationCodeHandler: ((VerificationInput?) -> Void)?
    private var trustedPhoneID = "1"
    private var preferSMS = false
    private var isAuthenticationCancellationRequested = false

    func submitVerificationCode() {
        guard !isVerificationCodeSubmitting,
              let verificationCodeHandler else { return }

        self.verificationCodeHandler = nil
        isVerificationCodeSubmitting = true
        verificationCodeHandler(.code(verificationCode))
    }

    func requestSMSCode() {
        guard !isVerificationCodeSubmitting,
              let verificationCodeHandler else { return }

        self.verificationCodeHandler = nil
        isVerificationCodeSubmitting = true
        verificationCodeHandler(.requestSMS)
    }

    func cancelAuthentication() {
        guard isLoginInProgress else { return }

        isAuthenticationCancellationRequested = true

        let verificationCodeHandler = verificationCodeHandler
        self.verificationCodeHandler = nil
        needVerificationCode = false
        verificationCode = ""
        isVerificationCodeSubmitting = false

        verificationCodeHandler?(nil)
    }
    
    func authenticate() async throws -> Bool {
        if isLoginInProgress {
            return false
        }
        
        logs = ""
        isLoginInProgress = true
        isAuthenticationCancellationRequested = false
        
        func logging(text: String) {
            Task { @MainActor [weak self] in
                self?.logs.append("\(text)\n")
            }
        }
        
        AnisetteDataHelper.shared.loggingFunc = logging

        defer {
            verificationCodeHandler = nil
            canRequestSMSCode = false
            trustedPhoneID = "1"
            preferSMS = false
            appleID = ""
            password = ""
            needVerificationCode = false
            verificationCode = ""
            isLoginInProgress = false
            isVerificationCodeSubmitting = false
            isAuthenticationCancellationRequested = false
        }

        do {
            // Both Anisette modes sign in through SideSign, which handles every 2FA
            // flow (trusted device, pushed code, SMS, voice). Only the source of the
            // Anisette headers differs.
            let portal = DeveloperPortal()
            func signIn() async throws -> AuthSession {
                let anisette = try await OnDeviceAnisetteHelper.shared.getSideSignAnisetteDataForCurrentMode()
                return try await portal.authenticate(
                    appleID: appleID, password: password, anisetteData: anisette,
                    xcodeVersion: "27.0 (27A5218g)",
                    accountRepairHandler: { _, _ in .cancel },
                    verificationHandler: { [weak self] request in
                        guard let self else { return .cancel }
                        return await self.handleSideSignVerification(request)
                    })
            }

            let result: AuthSession
            do {
                preferSMS = false
                result = try await signIn()
            } catch ServerError.badServerResponse(let reason, let payload)
                        where reason.hasPrefix("Trusted device request failed") && !isAuthenticationCancellationRequested {
                // Apple can reject the trusted-device push for some Anisette
                // providers (HTTP 500). Sign in again and have the code texted.
                logging(text: "\(reason)\n\(payload)")
                logging(text: "Trusted device push failed, retrying with SMS")
                preferSMS = true
                result = try await signIn()
            }
            // Keep StosSign's types for the existing App ID/signing UI only.
            guard let personID = Int(result.account.identifier) else {
                throw "SideSign returned an unsupported account identifier."
            }
            let accountData = try JSONSerialization.data(withJSONObject: [
                "email": result.account.appleID,
                "personId": personID,
                "dsFirstName": result.account.firstName,
                "dsLastName": result.account.lastName
            ])
            let account = try JSONDecoder().decode(Account.self, from: accountData)
            let session = AppleAPISession(dsid: result.session.dsid, authToken: result.session.authToken,
                anisetteData: try OnDeviceAnisetteHelper.shared.convert(result.session.anisetteData))
            let teams: [Team] = try await portal.fetchTeams(for: result.account, session: result.session).map { team in
                let type: TeamType
                switch team.type {
                case .free: type = .free
                case .individual: type = .individual
                case .organization: type = .organization
                case .unknown: type = .unknown
                }
                return Team(name: team.name, identifier: team.identifier, type: type, account: account)
            }

            guard !isAuthenticationCancellationRequested else {
                throw CancellationError()
            }

            logging(text: "Successfully signed in")

            DataManager.shared.model.account = account
            DataManager.shared.model.session = session
            Keychain.shared.appleIDEmailAddress = appleID
            Keychain.shared.appleIDPassword = password

            guard !teams.isEmpty else { throw "Unable to Fetch Team!" }
            logging(text: "Successfully fetched teams")
            availableTeams = teams

            return true
        } catch {
            if isAuthenticationCancellationRequested {
                throw CancellationError()
            }
            logs.append("Sign-in failed: \(error)\n")
            throw error
        }
    }

    private func prepareForVerification(using handler: @escaping (VerificationInput?) -> Void) {
        guard !isAuthenticationCancellationRequested else {
            handler(nil)
            return
        }

        verificationCodeHandler = handler
        verificationCode = ""
        needVerificationCode = true
        isVerificationCodeSubmitting = false
    }

    private func handleSideSignVerification(_ request: TwoFactorRequest) async -> TwoFactorResponse {
        guard !isAuthenticationCancellationRequested else { return .cancel }
        switch request {
        case .selectDeliveryMethod(let preferred, let phones):
            if let phone = phones.first { trustedPhoneID = phone.id }
            if preferred == .sms || preferSMS {
                logs.append("Requesting verification code by SMS\n")
                return .requestSMS(phoneID: trustedPhoneID)
            }
            logs.append("Requesting verification code on your trusted devices\n")
            return .requestTrustedDevice
        case .trustedDevice, .sms, .voice:
            if let error = request.error { logs.append("\(error)\n") }
            if case .trustedDevice = request {
                logs.append("Waiting for the code from your trusted devices\n")
                canRequestSMSCode = true
            } else if case .voice = request {
                logs.append("Code sent by phone call\n")
                canRequestSMSCode = false
            } else {
                logs.append("Code sent by SMS\n")
                canRequestSMSCode = false
            }
            logs.append("Enter the verification code above, then tap Continue\n")
            let input: VerificationInput? = await withCheckedContinuation { continuation in
                prepareForVerification { continuation.resume(returning: $0) }
            }
            guard let input, !isAuthenticationCancellationRequested else { return .cancel }
            switch input {
            case .code(let code):
                return .verificationCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
            case .requestSMS:
                logs.append("Requesting verification code by SMS\n")
                return .requestSMS(phoneID: trustedPhoneID)
            }
        }
    }
    
    func fetchTeams(for account: Account, session: AppleAPISession) async throws -> [Team]
    {

        let fetchedTeams = try await AppleAPI.shared.fetchTeamsForAccount(account: account, session: session)
        guard !fetchedTeams.isEmpty else {
            throw "Unable to Fetch Team!"
        }
        
        return fetchedTeams
    }
}
