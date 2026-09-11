# Use a native macOS interface

Target macOS first, using SwiftUI for interface content and AppKit for the notch panel and desktop window behavior. This fits the requested Mac experience while accepting that a future Windows or Linux version would need its own interface and platform integrations.

Keep session state and attention-queue rules independent of the macOS interface so they can be tested and changed separately. Do not build a cross-platform interface or a general plugin system in anticipation of future requirements; the exact module layout remains open.
