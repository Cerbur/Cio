import AppKit
import CioModel
import SwiftUI

/// A native popover, segmented picker, search field and buttons. The system
/// owns popover material, dismissal, focus and all control interaction feedback.
struct SpaceIconPicker: View {
  let icon: BrowserSpaceIcon
  let onSelect: (BrowserSpaceIcon) -> Void
  @State private var mode: Mode
  @State private var search = ""
  @State private var category = 0
  @FocusState private var searchFocused: Bool

  enum Mode: String, CaseIterable { case emoji = "Emoji", symbol = "Icon" }

  init(icon: BrowserSpaceIcon, onSelect: @escaping (BrowserSpaceIcon) -> Void) {
    self.icon = icon
    self.onSelect = onSelect
    _mode = State(initialValue: { if case .systemImage = icon { return .symbol }; return .emoji }())
  }

  private var choices: [SpaceIconChoice] {
    let all = mode == .emoji ? SpaceIconCatalog.emoji : SpaceIconCatalog.symbols
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return all.filter {
      if !query.isEmpty { return $0.searchText.localizedStandardContains(query) }
      return mode == .symbol || $0.category == category
    }
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Spacer(minLength: 0)
        Picker("Icon type", selection: $mode) {
          ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 156)
        Button {
          onSelect(.placeholder)
        } label: { Image(systemName: "trash") }
          .buttonStyle(.borderless)
          .help("Reset Space Icon")
          .accessibilityLabel("Reset Space Icon")
        Spacer(minLength: 0)
      }

      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(mode == .emoji ? "Search Emoji" : "Search Icons", text: $search)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .onSubmit { if let first = choices.first { onSelect(first.icon) } }
        if !search.isEmpty {
          Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Clear Search")
        }
      }
      .padding(8)
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }

      ScrollViewReader { proxy in
        ScrollView {
          Color.clear.frame(height: 0).id("top")
          if choices.isEmpty {
            ContentUnavailableView.search(text: search)
              .frame(maxWidth: .infinity, minHeight: 200)
          } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
              ForEach(choices) { choice in
                Button { onSelect(choice.icon) } label: {
                  SpaceIconView(icon: choice.icon, size: mode == .emoji ? 23 : 18)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                      if choice.icon == icon {
                        RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.1))
                      }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(choice.name)
                .accessibilityLabel(choice.name)
                .accessibilityAddTraits(choice.icon == icon ? [.isSelected] : [])
              }
            }
          }
        }
        .frame(height: 244)
        .onChange(of: category) { _, _ in proxy.scrollTo("top", anchor: .top) }
        .onChange(of: mode) { _, _ in proxy.scrollTo("top", anchor: .top) }
        .onChange(of: search) { _, _ in proxy.scrollTo("top", anchor: .top) }
      }

      if mode == .emoji {
        Divider()
        HStack(spacing: 0) {
          ForEach(Array(SpaceIconCatalog.categories.enumerated()), id: \.offset) { index, item in
            Button { category = index; search = "" } label: {
              Image(systemName: item.symbol)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .foregroundStyle(category == index ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(item.name)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(category == index ? [.isSelected] : [])
          }
        }
      }
    }
    .padding(16)
    .frame(width: 320)
    .onAppear {
      if let selected = SpaceIconCatalog.emoji.first(where: { $0.icon == icon }) { category = selected.category }
      searchFocused = true
    }
    .accessibilityIdentifier("space-icon-picker")
  }
}

struct SpaceIconChoice: Identifiable, Sendable {
  let value: String
  let name: String
  let category: Int
  let isSymbol: Bool
  var id: String { value }
  var icon: BrowserSpaceIcon { isSymbol ? .systemImage(value) : .emoji(value) }
  var searchText: String { "\(value) \(name) \(SpaceIconCatalog.categories[category].name)" }
}

enum SpaceIconCatalog {
  static let categories: [(name: String, symbol: String)] = [
    ("Smileys & People 表情 人物", "face.smiling"), ("Animals & Nature 动物 自然", "sun.max"),
    ("Food & Drink 食物 饮料", "cup.and.saucer"), ("Activities 活动 运动", "medal"),
    ("Travel & Places 旅行 地点", "car"), ("Objects 物品", "gift"),
    ("Symbols 符号", "heart"), ("Flags 旗帜", "flag")
  ]

  // Unicode names keep the complete catalog searchable without a second
  // hand-maintained localization table. Multi-scalar emoji stay intact.
  static let emoji: [SpaceIconChoice] = {
    let groups = [
      "😀 😃 😄 😁 😆 😅 😂 🤣 🥲 ☺️ 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😋 😛 😎 🤓 🧐 🤩 🥳 🤔 🤗 🤭 🫡 😴 😭 😤 🥺 😱 🤯 🫠 🤖 👻 👽 💩 🎃 😺 🙈 👋 👍 👏 🙌 🤝 🙏 💪 👀 🧠 👶 👧 🧒 👦 👩 🧑 👨 👵 🧓 👴 👩‍💻 🧑‍💻 👨‍💻 👩‍🎨 🧑‍🎨 👨‍🎨 👩‍🚀 🧑‍🚀 👨‍🚀 👩‍🔬 🧑‍🔬 👨‍🔬 👩‍🍳 🧑‍🍳 👨‍🍳 🥷 🧙 🧚 🧜 🦸 🦹",
      "🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐻‍❄️ 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🐤 🦆 🦉 🦇 🐺 🐴 🦄 🐝 🦋 🐌 🐞 🐢 🐍 🦎 🦕 🦖 🐙 🦑 🦀 🐠 🐬 🐳 🦈 🐘 🦒 🦔 🐿️ 🦥 🐾 🌵 🎄 🌲 🌳 🌴 🌱 🌿 🍀 🍁 🍄 🪴 🌷 🌸 🌹 🌻 🌞 🌝 🌚 🌙 ⭐ 🌟 ✨ ⚡ 🔥 🌈 ☀️ ⛅ ☁️ ❄️ 💧 🌊",
      "🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥝 🥑 🥦 🥬 🥒 🌶️ 🌽 🥕 🥔 🥐 🍞 🥖 🥨 🧀 🥚 🍳 🥞 🧇 🥓 🍔 🍟 🍕 🌭 🥪 🌮 🌯 🥗 🍜 🍝 🍣 🍱 🥟 🍙 🍚 🍛 🍤 🍦 🍨 🍩 🍪 🎂 🍰 🧁 🍫 🍿 🍯 🥛 ☕ 🍵 🧋 🧃 🥤 🍺 🍷 🥂 🍸",
      "⚽ 🏀 🏈 ⚾ 🎾 🏐 🏉 🥏 🎱 🪀 🏓 🏸 🏒 🥊 🥋 ⛳ 🏹 🎣 🛹 🛼 🛷 ⛸️ 🎿 🏂 🏋️ 🤸 🧘 🏄 🏊 🚴 🧗 🏆 🥇 🥈 🥉 🏅 🎖️ 🎗️ 🎫 🎪 🎭 🩰 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲 ♟️ 🎯 🎳 🎮 🧩",
      "🚗 🚕 🚙 🚌 🚎 🏎️ 🚓 🚑 🚒 🚐 🛻 🚚 🚛 🚜 🛵 🏍️ 🚲 🛴 🚂 🚆 🚄 🚇 🚊 ✈️ 🛫 🛬 🛩️ 🚀 🛸 🚁 ⛵ 🚤 🛳️ 🚢 ⚓ 🗺️ 🗿 🗽 🗼 🏰 🏯 🎡 🎢 ⛲ ⛱️ 🏖️ 🏝️ 🏜️ 🌋 ⛰️ 🏔️ 🏕️ ⛺ 🏠 🏡 🏢 🏬 🏥 🏦 🏨 🏫 🏛️ ⛪ 🕌 🌉 🌃 🌆 🌇",
      "⌚ 📱 💻 ⌨️ 🖥️ 🖨️ 🖱️ 💾 💿 📷 🎥 📺 📻 🎙️ 🧭 ⏱️ ⏰ ⌛ 🔋 🔌 💡 🔦 🕯️ 🧯 🛢️ 💸 💵 💰 💎 ⚖️ 🧰 🔧 🔨 ⚒️ 🛠️ ⚙️ 🧱 🔗 🧲 🧪 🧫 🧬 🔬 🔭 💊 🩺 🚪 🛏️ 🛋️ 🪑 🚿 🧹 🧺 🧻 🪥 🧸 🎁 🎈 🎉 ✉️ 📦 📚 📖 📓 📒 📃 📅 📌 📎 ✂️ 🖊️ ✏️ 🔍 🔐 🔑 🔔",
      "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❤️‍🔥 💕 💞 💓 💖 💘 💝 ☮️ ✝️ ☯️ ♈ ♉ ♊ ♋ ♌ ♍ ♎ ♏ ♐ ♑ ♒ ♓ 🆔 ⚛️ ☢️ ☣️ 🆚 🆘 ❌ ⭕ 🛑 ⛔ 🚫 💯 ❗ ❓ ✅ ♻️ 💹 ❇️ ✳️ ❎ 🌐 💠 🌀 💤 🔴 🟠 🟡 🟢 🔵 🟣 ⚫ ⚪ 🟤 🔺 🔻 🔸 🔹 🔶 🔷 🔳 🔲 🟩 🟦 🟪 🟨 🟥 🟧 🏁",
      "🏳️ 🏴 🏴‍☠️ 🏳️‍🌈 🏳️‍⚧️ 🚩 🎌 🇨🇳 🇭🇰 🇲🇴 🇹🇼 🇯🇵 🇰🇷 🇸🇬 🇮🇳 🇹🇭 🇻🇳 🇲🇾 🇮🇩 🇵🇭 🇦🇺 🇳🇿 🇺🇸 🇨🇦 🇲🇽 🇧🇷 🇦🇷 🇬🇧 🇫🇷 🇩🇪 🇮🇹 🇪🇸 🇵🇹 🇳🇱 🇧🇪 🇨🇭 🇦🇹 🇸🇪 🇳🇴 🇩🇰 🇫🇮 🇮🇸 🇮🇪 🇵🇱 🇨🇿 🇬🇷 🇹🇷 🇺🇦 🇿🇦 🇪🇬 🇦🇪 🇸🇦 🇮🇱 🇺🇳"
    ]
    return groups.enumerated().flatMap { category, group in
      group.split(separator: " ").map { value in
        let text = String(value)
        let name = text.applyingTransform(.toUnicodeName, reverse: false)?
          .replacingOccurrences(of: "\\N{", with: "").replacingOccurrences(of: "}", with: " ") ?? text
        return SpaceIconChoice(value: text, name: name, category: category, isSymbol: false)
      }
    }
  }()

  static let symbols: [SpaceIconChoice] = {
    let names = "star.fill bookmark.fill heart.fill flag.fill bolt.fill triangle.fill asterisk bell.fill lightbulb.fill drop.fill square.grid.2x2.fill circle.grid.3x3.fill square.3.layers.3d cylinder.split.1x2.fill archivebox.fill square.on.square.fill folder.fill tray.fill calendar envelope.fill checkmark.square.fill doc.fill book.fill ellipsis.bubble.fill person.2.fill terminal.fill hammer.fill square.fill oval.fill circle.fill moon.fill sun.max.fill globe.americas.fill leaf.fill cloud.fill pawprint.fill basket.fill gift.fill bed.double.fill fork.knife dumbbell.fill airplane music.note paintpalette.fill video.fill bandage.fill chevron.left.forwardslash.chevron.right sportscourt.fill map.fill tree.fill takeoutbag.and.cup.and.straw.fill newspaper.fill hand.thumbsup.fill tram.fill house.fill building.2.fill briefcase.fill graduationcap.fill laptopcomputer desktopcomputer gamecontroller.fill camera.fill headphones brain.head.profile sparkles flame.fill mountain.2.fill sailboat.fill car.fill bicycle cup.and.saucer.fill puzzlepiece.fill key.fill lock.fill shield.fill trophy.fill crown.fill diamond.fill atom infinity target scope paperplane.fill rocket.fill chart.bar.fill externaldrive.fill shippingbox.fill wrench.and.screwdriver.fill"
    return names.split(separator: " ").compactMap { value in
      let name = String(value)
      guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
      return SpaceIconChoice(value: name, name: name.replacingOccurrences(of: ".", with: " "), category: 6, isSymbol: true)
    }
  }()
}
