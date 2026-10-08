import Foundation
import Combine

enum AppLanguage: String, CaseIterable {
  case english = "en"
  case chinese = "zh-Hans"
}

extension Notification.Name {
  static let pebbleLanguageChanged = Notification.Name("Pebble.languageChanged")
}

@MainActor
final class Localization: ObservableObject {
  static let shared = Localization()

  @Published var language: AppLanguage {
    didSet {
      guard language != oldValue else { return }
      UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
      NotificationCenter.default.post(name: .pebbleLanguageChanged, object: nil)
    }
  }

  private init() {
    language = UserDefaults.standard.string(forKey: "appLanguage")
      .flatMap(AppLanguage.init(rawValue:)) ?? .english
  }
}

func tr(_ english: String, _ chinese: String) -> String {
  UserDefaults.standard.string(forKey: "appLanguage") == AppLanguage.chinese.rawValue ? chinese : english
}

struct LocalizedMessage {
  let english: String
  let chinese: String

  init(_ english: String, _ chinese: String) {
    self.english = english
    self.chinese = chinese
  }

  var text: String { tr(english, chinese) }
}
