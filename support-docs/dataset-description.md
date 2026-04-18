# Dataset Description — What the Data Looks Like

A plain-English description of the files, folders, timestamps, types, and sizes that make up the demo dataset. No implementation details. Share this with anyone who needs to understand what we're producing.

---

## Structure

A realistic enterprise file share. About 10 million files across roughly 50,000 folders organized by department — Sales, Marketing, Engineering, Finance, Legal, HR, IT, Executive, Operations, Customer Success, Product, Facilities — plus shared areas like Public, Scratch, and Archive.

Each department's structure mirrors what that team actually does:

- **Finance** — AP, AR, GL, Budgets, Audit, Tax, organized by fiscal year
- **Engineering** — Projects, Builds, Releases, Vendors
- **Marketing** — Campaigns, Brand Assets, Videos
- **Legal** — Contracts, NDAs, IP, Litigation
- **HR** — Employees, Payroll, Benefits, Policies
- **IT** — Software, Infrastructure, Backups, Logs, Security
- **Executive** — Board, Strategy, Investor, Acquisitions
- ...and so on for each department

## File types

About 35 extensions across the categories a real NAS accumulates:

- **Office** — docx, xlsx, pptx, doc, xls, pdf, rtf
- **Images** — jpg, png, gif, bmp, tiff, psd, ai
- **Archives** — zip, 7z, rar, tar, gz
- **Media** — mp4, mov, mp3, wav, avi
- **Installers / disk** — iso, msi, exe, vhdx
- **CAD and code** — dwg, step, py, js, json, xml
- **Text and logs** — txt, log, csv, md
- **Junk** — tmp, bak, Thumbs.db, .DS_Store, .lock

## File sizes

Sizes match what each type actually is:

- Word docs — a few hundred KB, not 2 GB
- Excel — typically under 5 MB
- PowerPoint — 5 to 40 MB
- PDFs — 100 KB to a few MB for normal docs, larger for scans
- JPG / PNG — tens of KB up to ~15 MB
- PSD — 5 MB to 500 MB
- ZIPs — a few MB to a few GB
- ISOs — 300 MB to 8 GB
- VHDX — 500 MB up to 60 GB
- MP4 video — 10 MB to multi-GB
- Logs and .bak files — can run into the tens of GB

## Timestamps

Every file has a creation time, modified time, and accessed time, and they progress in the order they should: **created first, modified at or after creation, accessed at or after modified.**

Sometimes a file is created and modified in the same session and never touched again. Sometimes it's created, edited weeks later, then accessed years after that. A small percentage have an ancient modified time but a recent access time — the "backup agent touched it last year" pattern.

## Age distribution

Age is heavily skewed old, the way real enterprise shares actually are:

- ~20% newer than 2 years
- ~30% 2 to 5 years old
- ~30% 5 to 10 years old
- ~20% 10 to 15 years old

That long tail is the point — real shares have been accumulating for a decade or more, and nobody's cleaned them up.

## Deliberate mess

The mess is the demo.

**Duplicates and version drift.** About 8% of files are exact duplicates of other files, sitting in different folders because people copy things around. A few percent are version-drift clusters — the same document saved as `Report.docx`, `Report_v2.docx`, `Report_FINAL.docx`, `Report_FINAL_USE_THIS.docx` side by side.

**Lopsided ownership.** 10% of users own roughly 60% of the bytes, with a few hoarders sitting on hundreds of GB of personal media or old backups. Service accounts like backup agents end up owning huge chunks of data.

**Lopsided capacity by file type.** By count, Office docs dominate. By capacity, a handful of fat types — ISOs, VHDX, video, PSD, ZIP — eat most of the space.

**Broken permissions on ~20% of folders.** Oversharing on sensitive folders (Payroll, HR, Legal, Exec), individuals granted access directly instead of through groups, files owned by ex-employees whose accounts were deleted, broken inheritance, and random users or service accounts owning folders they shouldn't.

---

**Bottom line:** it should look exactly like what a storage admin would find if they finally audited a share that's been accumulating for 10+ years and nobody's ever cleaned up.
