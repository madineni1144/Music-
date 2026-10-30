import SwiftUI
import Security

struct UserProfile: Codable {
    let id: String
    let email: String
    let name: String
}

@MainActor
final class UserAccount: ObservableObject {
    @Published private(set) var user: UserProfile?
    @Published private(set) var busy = false
    @Published var error: String?
    private var token: String?
    private var server: URL?

    private func keychainQuery(_ server: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "xyz.madineni.music.accounts",
         kSecAttrAccount as String: server.absoluteString]
    }

    func restore(serverText: String) async {
        guard !busy, let base = try? ServerAddress.parse(serverText), base.scheme == "https" else { return }
        if server == base, user != nil { return }
        server = base; user = nil; token = nil; error = nil
        var query = keychainQuery(base)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let saved = String(data: data, encoding: .utf8) else { return }
        token = saved; busy = true
        defer { busy = false }
        do { user = try await request("me", method: "GET").user }
        catch { self.error = error.localizedDescription }
    }

    func submit(serverText: String, name: String, email: String, password: String, register: Bool) async {
        guard !busy else { return }
        if register && !(8...12).contains(password.utf16.count) {
            error = "Use a password between 8 and 12 characters."
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let base = try ServerAddress.parse(serverText)
            guard base.scheme == "https" else { throw AccountError.message("Use an HTTPS server to sign in securely.") }
            server = base; token = nil; user = nil
            let response = try await request(register ? "register" : "login", method: "POST",
                                             body: ["name": name, "email": email, "password": password])
            guard let newToken = response.token else { throw AccountError.message("The server did not return a session.") }
            var query = keychainQuery(base)
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = Data(newToken.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw AccountError.message("Could not securely save your session. Please try again.")
            }
            token = newToken; user = response.user
        } catch { self.error = error.localizedDescription }
    }

    func updateName(_ name: String) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { user = try await request("me", method: "PATCH", body: ["name": name]).user }
        catch { self.error = error.localizedDescription }
    }

    func signOut() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await request("logout", method: "POST")
            if let server { SecItemDelete(keychainQuery(server) as CFDictionary) }
            token = nil; user = nil
        } catch { self.error = error.localizedDescription }
    }

    private struct Response: Decodable { let user: UserProfile?; let token: String? }
    private struct Failure: Decodable { let error: String }
    private func request(_ path: String, method: String, body: [String: String]? = nil) async throws -> Response {
        guard let server else { throw AccountError.message("Select a server first.") }
        var request = URLRequest(url: server.appendingPathComponent("api/auth/" + path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Never forward account credentials through an HTTP redirect.
        let session = URLSession(configuration: .ephemeral, delegate: AccountRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError.message("Invalid account response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, token != nil {
                SecItemDelete(keychainQuery(server) as CFDictionary); token = nil; user = nil
            }
            throw AccountError.message((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Account service unavailable (HTTP \(http.statusCode)).")
        }
        if http.statusCode == 204 { return Response(user: nil, token: nil) }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private enum AccountError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

private final class AccountRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct UserAccountPanel: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @StateObject private var account = UserAccount()
    @State private var register = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let user = account.user {
                Text(user.name).font(.title2.bold())
                Text(user.email).foregroundStyle(.secondary)
                TextField("Display name", text: $name).textContentType(.name)
                Button("Save name") { Task { await account.updateName(name) } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Sign out", role: .destructive) {
                    Task { await account.signOut(); if account.user == nil { player.clear() } }
                }
                Text("Favorites are saved on this device. Server playlists are shared.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(register ? "Create your account" : "Sign in").font(.title2.bold())
                if register { TextField("Name", text: $name).textContentType(.name) }
                TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(register ? "Password (8–12 characters)" : "Password", text: $password)
                    .textContentType(register ? .newPassword : .password)
                Button(register ? "Create account" : "Sign in") {
                    Task {
                        await account.submit(serverText: library.server?.absoluteString ?? library.serverText,
                                             name: name, email: email, password: password, register: register)
                        password = ""
                        name = account.user?.name ?? name
                    }
                }.buttonStyle(.borderedProminent).disabled(email.isEmpty || password.isEmpty || (register && name.isEmpty))
                Button(register ? "Already registered? Sign in" : "New here? Create an account") {
                    register.toggle(); password = ""; account.error = nil
                }
            }
            if account.busy { ProgressView() }
            if let error = account.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .disabled(account.busy)
        .task(id: library.server?.absoluteString ?? library.serverText) {
            await account.restore(serverText: library.server?.absoluteString ?? library.serverText)
            name = account.user?.name ?? ""
        }
    }
}

