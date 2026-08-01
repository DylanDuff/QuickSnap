//
//  UploadingSettingsView.swift
//  QuickSnap
//

import SwiftUI

/// Uploading tab: the master switch, the provider picker, the selected
/// provider's own configuration, and the provider-neutral behaviour and
/// button settings.
///
/// One provider is active at a time. Each one's fields live in its own
/// subview (`ImmichSettingsSection`, `S3SettingsSection`) so adding a
/// provider means adding a section and a case, not editing this file's
/// layout.
struct UploadingSettingsView: View {
    @AppStorage(AppSettings.Keys.uploadingEnabled)
    private var isEnabled = AppSettings.Defaults.uploadingEnabled

    @AppStorage(AppSettings.Keys.uploadProvider)
    private var provider = AppSettings.Defaults.uploadProvider

    @AppStorage(AppSettings.Keys.uploadAfterCapture)
    private var uploadsAfterCapture = AppSettings.Defaults.uploadAfterCapture

    @AppStorage(AppSettings.Keys.uploadCopiesLink)
    private var copiesLink = AppSettings.Defaults.uploadCopiesLink

    @AppStorage(AppSettings.Keys.checkUploadsForSensitiveContent)
    private var checksForSensitiveContent = AppSettings.Defaults.checkUploadsForSensitiveContent

    @AppStorage(AppSettings.Keys.uploadShowsPreviewButton)
    private var showsPreviewButton = AppSettings.Defaults.uploadShowsPreviewButton

    @AppStorage(AppSettings.Keys.markupShowsUploadButton)
    private var showsMarkupButton = AppSettings.Defaults.markupShowsUploadButton

    var body: some View {
        Form {
            Section("Uploading") {
                Toggle("Upload screenshots", isOn: $isEnabled)

                if isEnabled {
                    Picker("Provider", selection: $provider) {
                        ForEach(UploadProvider.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }

                    Text(provider.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isEnabled {
                switch provider {
                case .immich:
                    ImmichSettingsSection()
                case .s3:
                    S3SettingsSection()
                }

                Section("Behaviour") {
                    Toggle("Upload automatically after each capture", isOn: $uploadsAfterCapture)

                    Toggle(linkToggleTitle, isOn: $copiesLink)

                    Text(linkToggleFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Before Uploading") {
                    Toggle("Check captures for credentials", isOn: $checksForSensitiveContent)

                    Text("Looks for API keys, tokens, private keys and card numbers before a capture is uploaded. If one turns up, the upload waits and the screenshot opens so you can black it out. Nothing is sent until you've seen it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !checksForSensitiveContent {
                        Text("With this off, captures upload exactly as taken. A key that's visible in a screenshot becomes a link you can't take back.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Upload Buttons") {
                    Toggle("Show in the screenshot preview", isOn: $showsPreviewButton)
                        .disabled(uploadsAfterCapture)

                    Toggle("Show in the markup toolbar", isOn: $showsMarkupButton)

                    Text(uploadsAfterCapture
                        ? "The preview's upload button is hidden while automatic uploading is on — the capture has already been sent."
                        : "Choose where a manual upload button appears.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// "Copy a link" means different work per provider — a *new public
    /// shared link* on Immich, versus the object's existing URL on S3 — so
    /// the label says which.
    private var linkToggleTitle: String {
        switch provider {
        case .immich: return "Create a shareable link and copy it"
        case .s3: return "Copy the object's link"
        }
    }

    private var linkToggleFootnote: String {
        switch provider {
        case .immich:
            return "Shareable links are public to anyone who has them, and are not expired automatically."
        case .s3:
            return "The link only resolves if the bucket (or the public base URL below) serves objects publicly."
        }
    }
}


// MARK: - Immich

/// Immich's own configuration. Immich organises by **album** — its Folders
/// view is read-only and the upload endpoint has no path field — so this
/// offers an album picker rather than a folder chooser.
private struct ImmichSettingsSection: View {
    @AppStorage(AppSettings.Keys.immichServerURL)
    private var serverURLText = AppSettings.Defaults.immichServerURL

    @AppStorage(AppSettings.Keys.immichAlbumID)
    private var albumID = AppSettings.Defaults.immichAlbumID

    @AppStorage(AppSettings.Keys.immichAlbumName)
    private var albumName = AppSettings.Defaults.immichAlbumName

    @State private var apiKey = ""
    @State private var status = ConnectionStatus.untested
    @State private var albums: [ImmichAlbum] = []
    @State private var isLoadingAlbums = false
    @State private var isCreatingAlbum = false
    @State private var newAlbumName = ""

    /// Picker tag meaning "don't file it into an album" — Immich still
    /// stores the asset, it just lands in the library timeline only.
    private static let noAlbumTag = ""

    var body: some View {
        Section("Immich Server") {
            LabeledContent("Address") {
                TextField("https://immich.example.com", text: $serverURLText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabeledContent("API key") {
                HStack(spacing: 8) {
                    SecureField("Paste an API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Test") {
                        Task { await testConnection() }
                    }
                    .disabled(credentials == nil || status == .testing)
                }
            }

            ConnectionStatusRow(status: status)

            Text("Create a key in Immich under Account Settings → API Keys. It needs asset.upload, plus album.read and album.write for albums, and sharedLink.create for links.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Album") {
            LabeledContent("Upload to") {
                HStack(spacing: 8) {
                    Picker("Album", selection: albumSelection) {
                        Text("None (library only)").tag(Self.noAlbumTag)

                        if !albumChoices.isEmpty {
                            Divider()
                            ForEach(albumChoices) { album in
                                Text(album.albumName).tag(album.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .disabled(isLoadingAlbums)

                    if isLoadingAlbums {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") {
                            Task { await loadAlbums() }
                        }
                        .disabled(credentials == nil)
                    }

                    Button("New…") {
                        newAlbumName = ""
                        isCreatingAlbum = true
                    }
                    .disabled(credentials == nil)
                }
            }

            Text("Immich sorts uploads into albums rather than folders.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task {
            apiKey = KeychainStore.string(for: KeychainStore.Account.immichAPIKey) ?? ""
            if credentials != nil { await loadAlbums() }
        }
        .onChange(of: apiKey) { _, key in
            try? KeychainStore.setString(key, for: KeychainStore.Account.immichAPIKey)
            status = .untested
        }
        .onChange(of: serverURLText) { status = .untested }
        .alert("New Album", isPresented: $isCreatingAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                Task { await createAlbum() }
            }
            .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Creates the album on your Immich server and selects it for uploads.")
        }
    }

    /// Credentials from what's currently typed, so Test and the album list
    /// work while the feature is still being set up.
    private var credentials: ImmichCredentials? {
        guard let url = ImmichClient.normalizedServerURL(from: serverURLText), !apiKey.isEmpty else {
            return nil
        }
        return ImmichCredentials(serverURL: url, apiKey: apiKey)
    }

    /// The fetched albums, plus the saved one if it isn't in the list yet
    /// (albums haven't loaded, or it was deleted server-side) — otherwise
    /// the Picker would show an empty selection for a perfectly good
    /// stored album.
    private var albumChoices: [ImmichAlbum] {
        guard !albumID.isEmpty, !albums.contains(where: { $0.id == albumID }) else { return albums }
        return [ImmichAlbum(id: albumID, albumName: albumName.isEmpty ? "Saved album" : albumName)] + albums
    }

    /// Keeps the cached album *name* in step with the selected id — the
    /// upload toast names the album without needing a network round trip.
    private var albumSelection: Binding<String> {
        Binding(
            get: { albumID },
            set: { newValue in
                albumID = newValue
                albumName = albumChoices.first { $0.id == newValue }?.albumName ?? ""
            }
        )
    }

    private func testConnection() async {
        guard let credentials else { return }
        status = .testing
        do {
            let name = try await ImmichClient.currentUserName(credentials)
            status = .connected("Connected as \(name)")
            await loadAlbums()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func loadAlbums() async {
        guard let credentials else { return }
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }
        do {
            albums = try await ImmichClient.albums(credentials)
            // A stored album that no longer exists would otherwise sit in
            // the picker forever and fail every upload.
            if !albumID.isEmpty, !albums.contains(where: { $0.id == albumID }) {
                albumID = Self.noAlbumTag
                albumName = ""
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func createAlbum() async {
        guard let credentials else { return }
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let album = try await ImmichClient.createAlbum(named: name, credentials: credentials)
            albums.append(album)
            albums.sort { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
            albumID = album.id
            albumName = album.albumName
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}


// MARK: - S3

/// S3-compatible configuration. Unlike Immich this has real paths, so the
/// destination is a key prefix — a genuine folder.
private struct S3SettingsSection: View {
    @AppStorage(AppSettings.Keys.s3Endpoint)
    private var endpoint = AppSettings.Defaults.s3Endpoint

    @AppStorage(AppSettings.Keys.s3Region)
    private var region = AppSettings.Defaults.s3Region

    @AppStorage(AppSettings.Keys.s3Bucket)
    private var bucket = AppSettings.Defaults.s3Bucket

    @AppStorage(AppSettings.Keys.s3AccessKeyID)
    private var accessKeyID = AppSettings.Defaults.s3AccessKeyID

    @AppStorage(AppSettings.Keys.s3KeyPrefix)
    private var keyPrefix = AppSettings.Defaults.s3KeyPrefix

    @AppStorage(AppSettings.Keys.s3PublicBaseURL)
    private var publicBaseURL = AppSettings.Defaults.s3PublicBaseURL

    @AppStorage(AppSettings.Keys.s3UsesPathStyle)
    private var usesPathStyle = AppSettings.Defaults.s3UsesPathStyle

    @AppStorage(AppSettings.Keys.s3PublicRead)
    private var isPublicRead = AppSettings.Defaults.s3PublicRead

    @State private var secretKey = ""
    @State private var status = ConnectionStatus.untested

    var body: some View {
        Section("Bucket") {
            LabeledContent("Endpoint") {
                TextField("https://s3.example.com", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabeledContent("Bucket") {
                TextField("screenshots", text: $bucket)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabeledContent("Region") {
                TextField("us-east-1", text: $region)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Text("The endpoint is your service address without the bucket name. R2 and most MinIO setups ignore the region but still need one; us-east-1 works, or auto for R2.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Credentials") {
            LabeledContent("Access key ID") {
                TextField("AKIA…", text: $accessKeyID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabeledContent("Secret key") {
                HStack(spacing: 8) {
                    SecureField("Paste the secret access key", text: $secretKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Test") {
                        Task { await testConnection() }
                    }
                    .disabled(destination == nil || status == .testing)
                }
            }

            ConnectionStatusRow(status: status)
        }

        Section("Objects") {
            LabeledContent("Key prefix") {
                TextField("screenshots/", text: $keyPrefix)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabeledContent("Public base URL") {
                TextField("https://cdn.example.com (optional)", text: $publicBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Toggle("Use path-style addressing", isOn: $usesPathStyle)

            Toggle("Make uploads publicly readable", isOn: $isPublicRead)

            Text("Path-style is required by MinIO and works with R2 and B2. Turn it off for AWS S3. Set a public base URL if your files are served from a CDN or custom domain, which R2 does by default. R2 also rejects ACLs, so leave \"publicly readable\" off there and make the bucket public in Cloudflare instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task {
            secretKey = KeychainStore.string(for: KeychainStore.Account.s3SecretKey) ?? ""
        }
        .onChange(of: secretKey) { _, key in
            try? KeychainStore.setString(key, for: KeychainStore.Account.s3SecretKey)
            status = .untested
        }
        .onChange(of: endpoint) { status = .untested }
        .onChange(of: bucket) { status = .untested }
        .onChange(of: region) { status = .untested }
        .onChange(of: accessKeyID) { status = .untested }
    }

    /// Built from what's typed rather than from `AppSettings`, so Test works
    /// before the settings are committed to a working state.
    private var destination: S3Destination? {
        guard let endpointURL = S3Destination.normalizedEndpoint(from: endpoint),
              !bucket.isEmpty, !accessKeyID.isEmpty, !secretKey.isEmpty
        else {
            return nil
        }
        return S3Destination(
            configuration: S3Configuration(
                endpoint: endpointURL,
                region: region.isEmpty ? AppSettings.Defaults.s3Region : region,
                bucket: bucket,
                accessKeyID: accessKeyID,
                secretAccessKey: secretKey,
                keyPrefix: keyPrefix,
                publicBaseURL: publicBaseURL.isEmpty ? nil : publicBaseURL,
                usesPathStyle: usesPathStyle,
                isPublicRead: isPublicRead
            ),
            copiesLink: false
        )
    }

    private func testConnection() async {
        guard let destination else { return }
        status = .testing
        do {
            try await destination.testConnection()
            status = .connected("Bucket reachable")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}


// MARK: - Shared connection status

/// Result of the last Test — the only feedback that a provider's address
/// and credentials are actually good.
private enum ConnectionStatus: Equatable {
    case untested
    case testing
    case connected(String)
    case failed(String)
}

private struct ConnectionStatusRow: View {
    let status: ConnectionStatus

    var body: some View {
        switch status {
        case .untested:
            EmptyView()
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .connected(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


#Preview {
    UploadingSettingsView()
        .frame(width: 520, height: 450)
}
