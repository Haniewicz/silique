// Compiled together with the production Foundation-only language helper.
// Run each lookup through UserDefaults, not a cached process-only locale.
let previous = UserDefaults.standard.object(forKey: SiliqueLanguage.preferenceKey)
defer {
  if let previous = previous {
    UserDefaults.standard.set(previous, forKey: SiliqueLanguage.preferenceKey)
  } else {
    UserDefaults.standard.removeObject(forKey: SiliqueLanguage.preferenceKey)
  }
}
UserDefaults.standard.removeObject(forKey: SiliqueLanguage.preferenceKey)
precondition(SiliqueLanguage.text("English", "Polski") == "English")
precondition(SiliqueLanguage.setLanguage("pl"))
precondition(UserDefaults.standard.string(forKey: SiliqueLanguage.preferenceKey) == "pl")
precondition(SiliqueLanguage.text("English", "Polski") == "Polski")
precondition(!SiliqueLanguage.setLanguage("de"))
precondition(SiliqueLanguage.text("English", "Polski") == "Polski")
precondition(SiliqueLanguage.setLanguage("en"))
precondition(SiliqueLanguage.text("English", "Polski") == "English")
UserDefaults.standard.set("invalid", forKey: SiliqueLanguage.preferenceKey)
precondition(SiliqueLanguage.text("English", "Polski") == "English")
print("Native language probe passed")
