---
name: pdf-knowledge-import
description: 'Extract knowledge from NetApp PDF documentation and update skill reference files. Use when: user adds a new PDF, user asks to import PDF, update references from documentation, extract PDF content, process new documentation, add PDF knowledge to skills.'
argument-hint: 'Specify PDF filename and which skill(s) to update'
---

# PDF Knowledge Import

## When to Use
- User has added a new PDF to the `./PDF/` folder
- User asks to update skills with content from a PDF
- User wants to extract best practices, CLI commands, or procedures from NetApp documentation

## Prerequisites
- PDFs must be placed in the `./PDF/` folder at the workspace root
- Python with `pymupdf` is required for extraction

## Procedure

### Step 1 — Install pymupdf (if not already available)
```powershell
c:/python313/python.exe -m pip install pymupdf
```

### Step 2 — List Available PDFs
```powershell
Get-ChildItem -Path "./PDF" -Filter "*.pdf" | Select-Object Name, @{N='SizeMB';E={[math]::Round($_.Length/1MB,1)}}
```

### Step 3 — Extract PDF Table of Contents
Use this Python snippet to map the PDF structure:
```python
import pymupdf
doc = pymupdf.open("./PDF/<filename>.pdf")
print(f"Pages: {len(doc)}")
toc = doc.get_toc()
for level, title, page in toc[:200]:
    indent = "  " * (level - 1)
    print(f"{indent}{title} (p{page})")
```

### Step 4 — Extract Relevant Sections
Based on the TOC, extract pages relevant to each skill area:
```python
import pymupdf
doc = pymupdf.open("./PDF/<filename>.pdf")
text = ""
for p in range(start_page - 1, end_page):
    text += doc[p].get_text()
print(text[:15000])
```

Match sections to skills:
| PDF Topic | Target Skill | Reference File |
|-----------|-------------|----------------|
| SVM DR, SVM replication | `svm-dr` | `svm-dr/references/` |
| SnapMirror, replication, data protection | `snapmirror-management` | `snapmirror-management/references/` |
| Volume create, resize, move, FlexVol, FlexGroup | `volume-management` | `volume-management/references/` |
| LIF, ports, broadcast domain, failover, routing | `network-management` | `network-management/references/` |
| SVM/vserver create, protocols, export policies | `svm-management` | `svm-management/references/` |
| Cluster health, nodes, aggregates, overview | `ontap-cluster-info` | `ontap-cluster-info/references/` |

### Step 5 — Create or Update Reference Files
For each relevant section extracted, create a new reference file in the appropriate skill's `references/` folder:

```
.github/skills/<skill-name>/references/<descriptive-name>.md
```

Reference file format:
```markdown
# <Topic> — From <PDF Name>

## Key Points
- Bullet points of important facts

## CLI Commands
- Relevant commands with syntax

## Best Practices
- Do's and don'ts from the documentation
```

### Step 6 — Update SKILL.md (if needed)
If the PDF introduces new concepts or procedures not covered in the existing SKILL.md, add them to the relevant skill's body.

### Step 7 — Confirm with User
Show the user what was extracted and which skills were updated.

## Guidelines
- Keep reference files focused — one topic per file
- Use descriptive filenames (e.g., `nfs-best-practices.md`, `fabricpool-tiering.md`)
- Extract CLI commands, limits, version-specific features, and best practices
- Do NOT copy the entire PDF — extract only actionable, relevant content
- Summarize tables and large text blocks into concise reference format
- Always note the source PDF name and relevant page numbers
