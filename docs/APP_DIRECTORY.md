# Installed Apps

The Installed Apps page gives Osaurus a searchable local directory of macOS
applications. It reads application bundle names and identifiers from common
locations (`~/Applications`, `/Applications`, `/System/Applications`, and
CoreServices). It does not read app documents or application databases.

The directory marks the Apple apps with first-party Osaurus tool groups:
Calendar, Reminders, Contacts, Notes, Mail, Messages, Maps, Music, and
Shortcuts. Those tools remain opt-in per custom agent under **Agents → Tools**.
Other applications may be available through AppleScript or Computer Use when
the agent has the relevant capability and macOS permissions.

The page reports shared Accessibility and Screen Recording readiness. macOS
controls Apple Events automation grants per target app; those grants are
requested by macOS when an agent first uses an app and are not universally
queryable by Osaurus. The directory does not claim an arbitrary app is
connected just because its bundle is installed.

Apps found in nonstandard folders are not included in this initial scan.
