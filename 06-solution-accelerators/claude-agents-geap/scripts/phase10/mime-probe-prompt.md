# Phase 10 — GE MIME-rendering probe

**Goal:** discover which MIME types render as downloadable chips in
the Gemini Enterprise UI vs which surface as "Unsupported attachment."
Result determines the Path A (inline bytes) vs Path B (signed URL in
assistant text) routing matrix for Phase 10 Step 2.

## How to run

1. Open a fresh thread in the **PTA Co-Innovation Team** GE app.
2. Select the **Claude Code** agent.
3. Copy everything between the ─── lines below and paste it into the
   thread. Send.
4. Wait for the agent's final reply (it should say
   `Created and emitted all 9 MIME probe artifacts.`).
5. In the working pane, scroll through the 9 artifact emissions.
   For each one, note whether the chip renders normally or shows
   "Unsupported attachment" / equivalent UI error.
6. Fill in the results table at the bottom.

---

Use the claude_code tool to write each of the following 9 tiny files
to /workspace, then call emit_artifact on each in the same order. Do
NOT add any extra files. Do NOT read the files back or describe their
contents — the purpose is purely to surface each as a chip in the GE
UI. After all 9 emit_artifact calls complete, reply with the literal
line `Created and emitted all 9 MIME probe artifacts.`

The four text-based files have inline literal contents. The five
binary files are provided as base64; decode each into the named file.

```python
# /workspace/_mime_probe_setup.py — claude_code should run this and then
# emit_artifact on each of the 9 files it creates.
import base64, os

os.chdir('/workspace')

# 1. text/html
open('greeting.html', 'w').write(
    '<!DOCTYPE html><html><body>MIME probe: text/html</body></html>\n'
)

# 2. text/csv
open('data.csv', 'w').write('col1,col2\nvalue1,value2\n')

# 3. text/plain
open('notes.txt', 'w').write('MIME probe: plain text\n')

# 4. application/json
open('config.json', 'w').write('{"probe":"json","size":"tiny"}\n')

# 5. application/pdf
open('sample.pdf', 'wb').write(base64.b64decode("""
JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyAyIDAgUj4+ZW5kb2JqCjIgMCBvYmo8PC9UeXBlL1BhZ2VzL0NvdW50IDEvS2lkc1szIDAgUl0+PmVuZG9iagozIDAgb2JqPDwvVHlwZS9QYWdlL1BhcmVudCAyIDAgUi9NZWRpYUJveFswIDAgMjAwIDIwMF0vQ29udGVudHMgNCAwIFIvUmVzb3VyY2VzPDwvRm9udDw8L0YxIDUgMCBSPj4+Pj4+ZW5kb2JqCjQgMCBvYmo8PC9MZW5ndGggNDQ+PnN0cmVhbQpCVCAvRjEgMTggVGYgNTAgMTAwIFRkIChNSU1FIHByb2JlIFBERikgVGogRVQKZW5kc3RyZWFtIGVuZG9iago1IDAgb2JqPDwvVHlwZS9Gb250L1N1YnR5cGUvVHlwZTEvQmFzZUZvbnQvSGVsdmV0aWNhPj5lbmRvYmoKeHJlZgowIDYKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTYgMDAwMDAgbiAKMDAwMDAwMDEwOSAwMDAwMCBuIAowMDAwMDAwMjIzIDAwMDAwIG4gCjAwMDAwMDAzMDggMDAwMDAgbiAKdHJhaWxlcjw8L1NpemUgNi9Sb290IDEgMCBSPj4Kc3RhcnR4cmVmCjM2MwolJUVPRgo=
"""))

# 6. image/png
open('pixel.png', 'wb').write(base64.b64decode("""
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC
"""))

# 7. image/jpeg
open('pixel.jpg', 'wb').write(base64.b64decode("""
/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEBD/xAAfAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgv/xAC1EAACAQMDAgQDBQUEBAAAAX0BAgMABBEFEiExQQYTUWEHInEUMoGRoQgjQrHBFVLR8CQzYnKCCQoWFxgZGiUmJygpKjQ1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4eLj5OXm5+jp6vHy8/T19vf4+fr/xAAfAQADAQEBAQEBAQEBAAAAAAAAAQIDBAUGBwgJCgv/xAC1EQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRBxYTIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/aAAwDAQACEQMRAD8A+9A//Z
"""))

# 8. application/zip
open('archive.zip', 'wb').write(base64.b64decode("""
UEsDBBQAAAAAAB2ir1zZS5wVEAAAABAAAAAJAAAAaGVsbG8udHh0TUlNRSBwcm9iZTogemlwClBLAQIUAxQAAAAAAB2ir1zZS5wVEAAAABAAAAAJAAAAAAAAAAAAAACAAQAAAABoZWxsby50eHRQSwUGAAAAAAEAAQA3AAAANwAAAAAA
"""))

# 9. application/octet-stream
open('binary.bin', 'wb').write(base64.b64decode("""
//79TUlNRSBwcm9iZTogb2N0ZXQtc3RyZWFtIGJpbmFyeSBjb250ZW50//79
"""))

print('all 9 files written')
```

After running that script, call emit_artifact for each file in this
exact order:

1. `/workspace/greeting.html`
2. `/workspace/data.csv`
3. `/workspace/notes.txt`
4. `/workspace/config.json`
5. `/workspace/sample.pdf`
6. `/workspace/pixel.png`
7. `/workspace/pixel.jpg`
8. `/workspace/archive.zip`
9. `/workspace/binary.bin`

Finally reply with the single literal line:
`Created and emitted all 9 MIME probe artifacts.`

---

## Results table

Fill in the **Renders as chip?** column with `yes` (chip appears and
is downloadable) or `no` (UI shows "Unsupported attachment" or
similar). `partial` is for cases that render visually but error on
click; document the specific symptom in **Notes**.

| #   | MIME type                  | Filename       | Sniffed mime in tool args               | Renders as chip? | Notes |
| --- | -------------------------- | -------------- | --------------------------------------- | ---------------- | ----- |
| 1   | text/html                  | greeting.html  | `text/html`                            |                  |       |
| 2   | text/csv                   | data.csv       | `text/csv`                             |                  |       |
| 3   | text/plain                 | notes.txt      | `text/plain`                           |                  |       |
| 4   | application/json           | config.json    | `application/json`                     |                  |       |
| 5   | application/pdf            | sample.pdf     | `application/pdf`                      |                  |       |
| 6   | image/png                  | pixel.png      | `image/png`                            |                  |       |
| 7   | image/jpeg                 | pixel.jpg      | `image/jpeg`                           |                  |       |
| 8   | application/zip            | archive.zip    | `application/zip`                      |                  |       |
| 9   | application/octet-stream   | binary.bin     | `application/octet-stream`             |                  |       |

Once filled in, the routing matrix for Phase 10 Step 2 follows directly:
- `yes` rows → keep Path A (inline FilePart/FileWithBytes)
- `no` rows → switch to Path B (signed URL embedded in assistant text)
- `partial` rows → discuss before deciding
