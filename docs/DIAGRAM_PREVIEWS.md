# Diagram previews

Open a completed Mermaid code block with **Open diagram** for a dedicated viewer. Pinch to zoom, choose light/dark appearance, or use **Show source** to select and copy the original code. Back returns to the same chat. Streaming and unfinished blocks keep their source view.

Completed SVG blocks offer **Open SVG**. SVG output files use the same viewer after downloading through their original chat connection. The source toggle retains the SVG text and copy control. Web SVG links keep an explicit browser option and are not fetched automatically.

## Supported content and limits

Mermaid previews run locally on the phone. No remote rendering service or authenticated server address is sent to a renderer. Mermaid source is limited to 50,000 characters and 500 edges. Embedded media, clickable links and custom configuration directives are disabled.

SVG previews display the image without executing its scripts or providing clickable navigation. SVG source is limited to 262,144 characters and intrinsic dimensions of 8,192 pixels per side. External resources are unavailable, so self-contained SVG files work best.

Unsupported formats keep selectable source. Parse failures show an error with the original source available. These viewers have no file, network or device access beyond their bundled renderer. For interactive HTML and other formats, see [Output viewers](OPENING_OUTPUT_FILES.md).
