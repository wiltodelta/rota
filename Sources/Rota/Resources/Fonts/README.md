# Interface and chat fonts

Rota bundles unmodified TrueType fonts and registers them only for its own
process. IBM Plex Sans is the interface face and the default chat text face;
JetBrains Mono is the default chat code face. Both families use SIL Open Font
License 1.1; each directory includes its upstream copyright and license notice
in `OFL.txt`.

| Family | Upstream revision | Files |
| --- | --- | --- |
| IBM Plex Sans | [IBM/plex, 71f5589](https://github.com/IBM/plex/tree/71f558992315a12ca1f06a2215d57962a1992162/packages/plex-sans/fonts/complete/ttf) | Regular, Italic, SemiBold, SemiBoldItalic, Bold, BoldItalic |
| JetBrains Mono | [JetBrains/JetBrainsMono, 1937130](https://github.com/JetBrains/JetBrainsMono/tree/19371302b95d218af43299bce79ddbddd0bc364d/fonts/ttf) | Regular, Italic, Bold, BoldItalic |

To update, copy these faces from a pinned upstream revision and refresh the
matching license notice (Plex's `license.txt` beside its fonts, JetBrains
Mono's repository-root `OFL.txt`). Update the revision above. Run the maintenance
gate and inspect a packaged development build with interface text, native
controls, prose, headings, emphasis, inline code and a fenced code block.
Verify the resource bundle is included
and the chosen fonts resolve without relying on a system installation.
