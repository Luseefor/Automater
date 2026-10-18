# Support policy

Supported platform: macOS 14 or later. Provide the Tandem version, macOS version, a reproducible sequence, and any relevant local diagnostic category when reporting a problem. Do not include passwords, macro contents containing sensitive text, or private documents.

Tandem supports standard macOS accessibility and synthetic-event delivery. Compatibility with secure prompts and apps that reject automated input is not guaranteed.

Fast background mouse bursts use a dynamically resolved CoreGraphics window-location compatibility symbol. When that symbol is unavailable, use Accessibility delivery or Foreground. Burst timing depends on the target app; inactive-Space Accessibility actions can take longer than the ~100ms target.
