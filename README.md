# Deadlines

A macOS menu bar app for tracking deadlines, with reminders 1 day before, 1 hour before, and when due. Data is stored in `~/.deadlines.json`.

You can add a deadline by selecting a region of the screen: the screenshot is read by Gemini (`gemini-flash-latest`), falling back to on-device Vision text recognition. Store your Gemini API key in the login keychain:

```sh
security add-generic-password -s deadlines-gemini -a gemini -w <your-key>
```

Deadlines sync both ways with a "Deadlines" list in Apple Reminders (and through iCloud to your other devices). Title, time and notes edited in Reminders, and items added there, come back to the app. Only the app can complete or delete a deadline: a reminder ticked or deleted elsewhere is restored, so an accidental tap on the phone can't lose it.

A deadline marked Done before it's due stays in the main list (with a ✓) until it's due, then moves to Completed. In Reminders it shows as "✅ title", unticked, until then.

## Build

Builds the app into `~/Applications/Deadlines.app` (the source stays in this repo):

```sh
APP=~/Applications/Deadlines.app
mkdir -p $APP/Contents/MacOS
cp Info.plist $APP/Contents/
swiftc -O main.swift -o $APP/Contents/MacOS/Deadlines
codesign --force -s "Deadlines Local Signing" --identifier com.user.deadlines $APP
```

Sign with a stable (self-signed) certificate rather than ad-hoc (`-s -`), otherwise macOS asks for Screen Recording permission again after every rebuild.

## Run at login

```sh
cp com.user.deadlines.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.deadlines.plist
```
