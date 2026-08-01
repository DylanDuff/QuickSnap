import SwiftUI
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case markup = "Markup"
    case hotkeys = "Hotkeys"
    case uploading = "Uploading"
    case advanced = "Advanced"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:
            return "gearshape.fill"
        case .markup:
            return "paintbrush.fill"
        case .hotkeys:
            return "command"
        case .uploading:
            return "arrow.up.circle.fill"
        case .advanced:
            return "slider.horizontal.3"
        case .about:
            return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .general:
            return .gray
        case .markup:
            return Color(
                red: 106 / 255,
                green: 176 / 255,
                blue: 76 / 255
            )
        case .hotkeys:
            return Color(
                red: 235 / 255,
                green: 77 / 255,
                blue: 75 / 255
            )
        case .uploading:
            return Color(
                red: 34 / 255,
                green: 166 / 255,
                blue: 179 / 255
            )
        case .advanced:
            return Color(
                red: 240 / 255,
                green: 147 / 255,
                blue: 43 / 255
            )
            //rgb(240, 147, 43)
        case .about:
            return Color(
                red: 112 / 255,
                green: 81 / 255,
                blue: 246 / 255
            )
        }
    }
}

struct SettingsIcon: View {
    let systemName: String
    let color: Color
    
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
            }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(SettingsSection.allCases) { section in
                    HStack {
                        SettingsIcon(
                            systemName: section.icon,
                            color: section.iconColor
                        )

                        Text(section.rawValue)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selection == section ? .white.opacity(0.1) : .clear)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = section
                    }
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.horizontal, 0, for: .scrollContent)
        } detail: {
            detailContent
        }
        .toolbar(removing: .title)
        .frame(width: 700, height: 450)
        .background(.thinMaterial)
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .general:
            GeneralSettingsView()

        case .markup:
            MarkupSettingsView()

        case .hotkeys:
            HotkeysSettingsView()

        case .uploading:
            UploadingSettingsView()

        case .advanced:
            PlaceholderSettingsSection(title: "Advanced")

        case .about:
            AboutSettingsView()

        case nil:
            EmptyView()
        }
    }

}


// MARK: - Placeholder

struct PlaceholderSettingsSection: View {
    let title: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.red)

                }
            
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("This section is coming soon.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - About

struct AboutSettingsView: View {
    private let appIcon: Image
    private let appName: String
    private let appVersion: String
    private let appBuild: String
    private let copyright: String
    
    init() {
        if let nsIcon = Bundle.main.primaryAppIcon {
            appIcon = Image(nsImage: nsIcon)
        } else {
            appIcon = Image(systemName: "app.fill")
        }
        
        appName = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleName"
        ) as? String ?? "Unknown App"
        
        appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        
        appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        
        copyright = Bundle.main.object(
            forInfoDictionaryKey: "NSHumanReadableCopyright"
        ) as? String ?? ""
    }
    
    var body: some View {
        VStack(spacing: 20) {
            
            VStack(spacing: 14) {
                appIcon
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 22)
                    )
                    .shadow(
                        color: .black.opacity(0.15),
                        radius: 8,
                        y: 4
                    )
                
                Text(appName)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Version \(appVersion) (\(appBuild))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 30)
            
            
            VStack(spacing: 0) {
                AboutRow(
                    icon: "checkmark.circle.fill",
                    title: "Status",
                    value: "Up to date"
                )
                
                Divider()
                
                AboutRow(
                    icon: "doc.text.fill",
                    title: "Build",
                    value: appBuild
                )
            }
//            .background(.thinMaterial)
            .clipShape(
                RoundedRectangle(cornerRadius: 12)
            )
            .padding(.horizontal, 40)
            
            
            Spacer()
            
            Text(copyright)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - About Row

struct AboutRow: View {
    let icon: String
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            
            Text(title)
            
            Spacer()
            
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}


// MARK: - App Icon

private extension Bundle {
    var primaryAppIcon: NSImage? {
        guard
            let iconName = infoDictionary?["CFBundleIconName"] as? String
        else {
            return nil
        }

        return NSImage(named: iconName)
    }
}


#Preview {
    SettingsView()
        .frame(width: 700, height: 450)
}
