# Deadlines

A macOS menu bar app for tracking deadlines, with reminders 1 day before, 1 hour before, and when due. Data is stored in `~/.deadlines.json`.

You can add a deadline by selecting a region of the screen: the screenshot is read by DeepSeek Harness (headless, signed in with a DeepSeek account via `dsh-account.yml`), falling back to on-device Vision text recognition.

Deadlines sync both ways with a "Deadlines" list in Apple Reminders (and through iCloud to your other devices). Title, time and notes edited in Reminders, and items added there, come back to the app. Only the app can complete or delete a deadline: a reminder ticked or deleted elsewhere is restored, so an accidental tap on the phone can't lose it.

A deadline marked Done before it's due stays in the main list (with a ✓) until it's due, then moves to Completed. In Reminders it shows as "✅ title", unticked, until then.

## Build

```sh
swiftc -O main.swift -o Deadlines.app/Contents/MacOS/Deadlines
codesign --force -s "Deadlines Local Signing" --identifier com.user.deadlines Deadlines.app
```

Sign with a stable (self-signed) certificate rather than ad-hoc (`-s -`), otherwise macOS asks for Screen Recording permission again after every rebuild.

## Run at login

```sh
cp com.user.deadlines.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.deadlines.plist
```
