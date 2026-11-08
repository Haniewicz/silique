/// Device UI language, shared with pure-Dart storage and service diagnostics.
/// Never infer a language from note contents or translate user-authored data.
String currentLanguageCode = 'en';

String tr(String polish, String english) =>
    currentLanguageCode == 'pl' ? polish : english;
