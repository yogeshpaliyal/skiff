import SwiftUI

/** Skiff's colors: the brand's violet → teal, and a green for "connected". */
enum Brand {
    static let violet = Color(red: 0x6A / 255, green: 0x3D / 255, blue: 0xF0 / 255)
    static let teal = Color(red: 0x0F / 255, green: 0xB8 / 255, blue: 0xA9 / 255)
    static let green = Color(red: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255)
    static let gradient = LinearGradient(colors: [violet, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/** A rounded panel: the cards and sections of every screen. */
struct Panel<Content: View>: View {
    var tint: Color = Color(.secondarySystemGroupedBackground)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct SectionHeader<Action: View>: View {
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack {
            Text(text).font(.headline).foregroundStyle(Color.accentColor)
            Spacer()
            action
        }
        .padding(.top, 8)
    }
}

extension SectionHeader where Action == EmptyView {
    init(_ text: String) { self.init(text: text) { EmptyView() } }
}

/** A message: info, or a problem (red). */
struct NoteCard: View {
    let text: String
    var error = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(error ? Color.red : Color.accentColor)
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(error ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct Pill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/** A poster (or the kind of thing it is, while it loads or when there's none). */
struct Poster: View {
    let url: String?
    let symbol: String
    var width: CGFloat = 52
    var height: CGFloat = 78

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.15))
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/** Season or episode: − number +. */
struct NumberStepper: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { if value > 1 { value -= 1 } } label: { Image(systemName: "minus").frame(width: 36, height: 36) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).disabled(value <= 1)
                Text("\(value)").font(.title.bold()).monospacedDigit().frame(minWidth: 44)
                    .contentTransition(.numericText())
                Button { value += 1 } label: { Image(systemName: "plus").frame(width: 36, height: 36) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/** A choice card: an app or a TV, the picked one marked. */
struct ChoiceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.accentColor.opacity(0.15)))
                    Image(systemName: symbol).font(.title3).foregroundStyle(selected ? Color.white : Color.accentColor)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(16)
            .background(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/** "5 minutes ago". */
func relativeTime(_ millis: Int64) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(millis) / 1000), relativeTo: Date())
}

/** One history or saved entry: poster, name, what was used and when; bookmark and Play. */
struct EntryRow: View {
    let entry: Library.Entry
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onToggleSaved: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    Poster(url: entry.poster, symbol: entry.link != nil ? "tv" : entry.series ? "rectangle.stack" : "film")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline).lineLimit(2).foregroundStyle(.primary)
                        Text(details).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if entry.plays > 0 {
                            Text(entry.plays == 1 ? "Played once" : "Played \(entry.plays) times").font(.caption).foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onToggleSaved) {
                Image(systemName: entry.saved ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(entry.saved ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(entry.saved ? "Remove from saved" : "Save for later")
            Button(action: onPlay) { Image(systemName: "play.fill").frame(width: 30, height: 30) }
                .buttonStyle(.bordered).buttonBorderShape(.circle)
                .accessibilityLabel("Play on TV")
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var details: String {
        let what: String
        if let l = entry.link { what = entry.app ?? Links.site(l) } else if entry.series { what = "S\(entry.season) E\(entry.episode)" } else { what = "Movie" }
        return [what, entry.year, relativeTime(entry.lastUsed)].compactMap { $0 }.joined(separator: " · ")
    }
}
