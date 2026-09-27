#!/usr/bin/env python3
"""Magazine-page Sunday crossword handler.

Takes a single-page magazine-style NYT Sunday crossword PDF and produces:
1. A cropped/enlarged puzzle grid page
2. A cleanly formatted clue sheet (two sets printed by the caller)

Usage:
    python3 magazine_sunday.py input.pdf output.pdf
"""

import sys
import re
from pypdf import PdfReader, PdfWriter
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Table,
                                TableStyle, Image, BalancedColumns)
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.lib import colors
from io import BytesIO
from pdf2image import convert_from_path


def _extract_blurb(meta_text):
    """Pull the readable theme note / author bio out of the editorial metadata
    the PDF interleaves with the clues.

    Strips the editor credit, the byline, and the all-caps letterspaced title
    line (e.g. "BIG DRA W", which the text layer mangles) so only the prose
    blurb remains. Returns "" when there's nothing usable.
    """
    if not meta_text:
        return ""
    # Drop the leading editor-credit line ("Puzzles Edited by Will Shortz ...")
    b = re.sub(r'^.*?(?:Puzzles\s+Edited by|Edited by)[^\n]*\n', '', meta_text, flags=re.DOTALL)
    # Drop the trailing byline ("By <constructor>")
    b = re.sub(r'\n\s*By\s+[A-Z].*$', '', b, flags=re.DOTALL)
    lines = [ln.strip() for ln in b.split('\n') if ln.strip()]
    # Drop trailing all-caps title line(s) — the blurb's prose is mixed-case
    while lines and re.sub(r'[^A-Za-z]', '', lines[-1]) \
            and re.sub(r'[^A-Za-z]', '', lines[-1]).isupper():
        lines.pop()
    blurb = re.sub(r'\s+', ' ', ' '.join(lines)).strip()
    blurb = re.sub(r'\s+([,.;:!?])', r'\1', blurb)  # heal space-before-punctuation
    return blurb


# NOTE (2026-09-27), so nobody "fixes" this again: clues for the wrap-around theme
# answers arrive looking mangled --
#   '… in global commerce) (Conflict …'   for 19-Across
# I wrote a normaliser that inverted them into 'Conflict … in global commerce', tested
# it six-for-six, and it was WRONG. xian asked whether the split was intentional, and
# rendering the source PDF's own clue column settles it: the NYT prints them exactly
# that way, second half first --
#   28   ... outdoor festivals)
#        (Bathrooms at ...
# It is the theme. The answers circle back, so the clues circle back: you read the
# parenthesised half going out and the ellipsis half coming home. The extraction was
# faithful and the "gaps" xian saw in the printed columns are the real typesetting.
# DO NOT normalise these. Reproducing the source is the job.


def extract_clues(pdf_path):
    """Extract clue text from the PDF and parse into ACROSS and DOWN lists.

    Handles puzzle titles that may contain the words ACROSS or DOWN
    (e.g. "GOING DOWN FAST") by finding the section headers that are
    followed by numbered clues, not just the first occurrence.
    """
    reader = PdfReader(pdf_path)
    text = reader.pages[0].extract_text()

    # Find ALL occurrences of ACROSS and DOWN, then pick the ones that
    # are actual section headers (followed by numbered clues).
    across_positions = [m.start() for m in re.finditer(r'\bACROSS\b', text)]
    down_positions = [m.start() for m in re.finditer(r'\bDOWN\b', text)]

    def is_clue_header(pos, keyword):
        """Check if a keyword occurrence is a real section header by looking
        for numbered clues shortly after it."""
        after = text[pos + len(keyword):pos + len(keyword) + 40]
        return bool(re.search(r'\d{1,3}\s+\S', after))

    # Find the real ACROSS header
    across_pos = None
    for pos in across_positions:
        if is_clue_header(pos, 'ACROSS'):
            across_pos = pos
            break

    # Find the real DOWN header — must come after ACROSS
    down_pos = None
    for pos in down_positions:
        if across_pos is not None and pos <= across_pos:
            continue  # skip DOWN occurrences before ACROSS
        if is_clue_header(pos, 'DOWN'):
            down_pos = pos
            break

    if across_pos is None or down_pos is None:
        print(f"WARNING: Could not find ACROSS/DOWN clue sections in text")
        print(f"  ACROSS candidates: {across_positions}")
        print(f"  DOWN candidates: {down_positions}")
        return None, None, "", ""

    print(f"Found ACROSS at position {across_pos}, DOWN at position {down_pos}")

    # Extract title — look for the puzzle title (usually theme or author info)
    title = ""
    pre_across = text[:across_pos]
    for line in pre_across.split('\n'):
        line = line.strip()
        if line and 'Edited by' not in line and 'Puzzles' not in line and len(line) > 3:
            title = line
            break

    def _strip_grid_rows(region):
        """Drop lines that are only grid cell-numbers (two or more numbers,
        no letters). The PDF text layer interleaves these in-grid numbers with
        the clues, and on non-square layouts they can land *between* clue runs
        rather than after them."""
        return '\n'.join(
            ln for ln in region.split('\n')
            if not re.match(r'^\s*\d{1,3}(?:\s+\d{1,3})+\s*$', ln)
        )

    across_text = _strip_grid_rows(text[across_pos + len('ACROSS'):down_pos])
    down_text = _strip_grid_rows(text[down_pos + len('DOWN'):])

    # Capture, then excise, editorial metadata (editor credit, author bio,
    # title, byline) from the DOWN region. We remove each block only up to the
    # next clue boundary (or end of text) instead of truncating everything
    # after it — otherwise a non-square grid, whose layout splits the DOWN
    # clues into runs straddling the grid/metadata, would lose every clue after
    # the first run. The captured text feeds the optional clue-sheet blurb.
    meta_re = re.compile(
        r'(?:Puzzles\s+Edited by|Edited by|(?:^|\n)\s*By\s+[A-Z]|Play all)'
        r'.*?(?=\n\s*\d{1,3}\s+\S|\Z)',
        flags=re.DOTALL)
    blurb = _extract_blurb('\n'.join(meta_re.findall(down_text)))
    down_text = meta_re.sub(' ', down_text)

    def parse_clues(clue_text):
        """Parse numbered clues from text, handling multi-column PDF extraction."""
        clues = []
        boundaries = list(re.finditer(r'(?:^|\n)\s*(\d{1,3})\s+', clue_text))

        for i, match in enumerate(boundaries):
            num = int(match.group(1))
            start = match.end()
            if i + 1 < len(boundaries):
                end = boundaries[i + 1].start()
            else:
                end = len(clue_text)

            clue = clue_text[start:end].strip()
            clue = re.sub(r'\s+', ' ', clue)
            if not clue:
                continue
            if re.match(r'^[\d\s]+$', clue):
                continue

            # Handle cases where multiple clues got merged on one line
            parts = re.split(r'\s+(\d{1,3})\s+(?=[A-Z"\'\(_])', clue)
            if len(parts) > 1:
                first_clue = parts[0].strip()
                if first_clue and not re.match(r'^[\d\s]+$', first_clue):
                    clues.append((num, first_clue))
                j = 1
                while j < len(parts) - 1:
                    sub_num = int(parts[j])
                    sub_clue = parts[j + 1].strip()
                    if sub_clue and not re.match(r'^[\d\s]+$', sub_clue):
                        clues.append((sub_num, sub_clue))
                    j += 2
            else:
                clues.append((num, clue))

        clues.sort(key=lambda x: x[0])
        seen = set()
        deduped = []
        for num, clue in clues:
            if num not in seen:
                seen.add(num)
                deduped.append((num, clue))
        return deduped

    across_clues = parse_clues(across_text)
    down_clues = parse_clues(down_text)

    return across_clues, down_clues, title, blurb


def find_grid_bounds(img):
    """Auto-detect the puzzle grid boundaries in the rendered page image.

    1. Find the grid's vertical extent from very-dark pixel density peaks.
       Grid lines and black squares are far denser than clue text (which
       renders as anti-aliased gray), so a high threshold isolates them.
    2. Find the horizontal extent by measuring column density ONLY within
       that vertical band — this keeps clue text above/below the grid from
       diluting the signal and sharpens the left/right borders.
    3. Trust the detected box for any plausible crossword aspect ratio
       (square 21x21, tall, or wide themed grids alike). Crosswords are NOT
       always square: themed Sundays can be tall or wide rectangles. Only
       when the aspect is implausible — a sign detection failed or captured
       stray clue text — fall back to a row-derived square centered on the
       column cluster.
    """
    import numpy as np
    w, h = img.size
    arr = np.array(img.convert('L'))  # grayscale

    # Very dark pixels only (< 30) — grid lines and black squares
    # Text is typically lighter than pure black grid elements
    vdark = arr < 30

    # Step 1: Find grid vertical extent using high-density rows
    # Grid border lines have density > 0.25; text rarely does
    row_d = vdark.sum(axis=1) / w
    peak_rows = np.where(row_d > 0.25)[0]
    if len(peak_rows) < 5:
        peak_rows = np.where(row_d > 0.10)[0]
    if len(peak_rows) < 5:
        print("WARNING: Could not find grid rows via density peaks")
        return None

    top = int(peak_rows[0])
    bottom = int(peak_rows[-1])
    grid_h = bottom - top

    if grid_h < h * 0.15:
        print(f"WARNING: Detected grid height too small ({grid_h}px, {grid_h*100/h:.0f}% of page)")
        return None

    # Step 2: Find column extent, measuring density only within the grid's
    # vertical band so clue text outside it can't pull the borders wide
    band = vdark[top:bottom + 1, :]
    col_d = band.sum(axis=0) / (bottom - top + 1)
    peak_cols = np.where(col_d > 0.25)[0]
    if len(peak_cols) < 5:
        peak_cols = np.where(col_d > 0.10)[0]
    if len(peak_cols) < 5:
        print("WARNING: Could not find grid columns via density peaks")
        return None

    # 2026-09-13: take the largest CONTIGUOUS CLUSTER of peak columns, not the
    # outermost extremes. Puzzle 24416's magazine layout carried a full-height
    # vertical rule at col ~140 — one solid-black column, far left of the grid.
    # peak_cols[0]/[-1] let that single stray column drag the left edge from
    # ~1100 to 140; the resulting aspect (1.73) still cleared MAX_ASPECT=2.0,
    # so the wide box was ACCEPTED and page 1 printed the grid at half size
    # with the clues beside it. A real grid is a dense run of dark columns
    # (a line every cell); page furniture is isolated. Cluster with a gap
    # tolerance and keep the cluster containing the most peak columns — a
    # lone rule can never outvote the grid.
    gap_tol = max(20, grid_h // 8)  # cells are ~grid_h/21; allow a few cells
    clusters = []
    start = prev = int(peak_cols[0])
    count = 1
    for c in peak_cols[1:]:
        c = int(c)
        if c - prev > gap_tol:
            clusters.append((start, prev, count))
            start, count = c, 0
        prev = c
        count += 1
    clusters.append((start, prev, count))
    best = max(clusters, key=lambda t: t[2])
    if len(clusters) > 1:
        rejected = [(a, b, n) for (a, b, n) in clusters if (a, b, n) != best]
        print(f"Column clusters: kept {best[0]}-{best[1]} ({best[2]} peaks); "
              f"rejected {', '.join(f'{a}-{b} ({n})' for a, b, n in rejected)}")
    col_left, col_right = best[0], best[1]
    col_center = (col_left + col_right) / 2
    col_w = col_right - col_left

    # Step 3: Accept the detected box for any plausible crossword shape.
    # NYT grids are rectangles of square cells — usually 21x21, but themed
    # Sundays can be tall (e.g. 15x21) or wide. An implausible aspect signals
    # a detection problem (e.g. dark clue text captured to the side), in which
    # case the reliable row extent defines a centered-square fallback.
    # Window tightened 2026-09-27. NYT grids are rectangles of SQUARE cells, so the
    # only shapes that actually occur are 15x15 and 21x21 (1.00), 15x21 (0.71) and
    # 21x15 (1.40). The old 0.5-2.0 window accepted a crop twice as tall or twice as
    # wide as any real grid, so it was not discriminating between "a grid" and "a grid
    # plus a column of clue text". It had already failed once at 1.73 (see the note
    # above, which recorded the miss without narrowing the window), and again on
    # 2026-09-27 at 0.53 -- a 1456x2736 crop of a 21x21 puzzle, which xian noticed on
    # the printed sheet. 0.62-1.60 brackets the real shapes with headroom.
    MIN_ASPECT, MAX_ASPECT = 0.62, 1.60
    aspect = col_w / grid_h if grid_h > 0 else 0
    if MIN_ASPECT <= aspect <= MAX_ASPECT:
        left = col_left
        right = col_right
        print(f"Detected grid aspect={aspect:.2f} (accepted) — cols {left}-{right}")
    else:
        # Square off the COLUMN width, not the row height. When these two disagree it
        # is almost always the row extent that is wrong: the column cluster is found by
        # peak separation and reports which candidates it rejected, whereas the row
        # extent has nothing below the grid to stop it running on into the clue block.
        # On 2026-09-27 cols gave 1430px (clean: 67 peaks kept, two clusters rejected)
        # while rows gave 2736px, i.e. 84% of the page height for a grid occupying its
        # top half. Squaring grid_h there would have produced a 2736x2736 crop -- wrong
        # in the same direction, only larger.
        left, right = col_left, col_right
        bottom = min(h, top + col_w)
        print(f"Implausible aspect={aspect:.2f}; squared off the column width instead "
              f"— cols {left}-{right}, rows {top}-{bottom} (row extent {grid_h}px rejected)")

    # Add small padding
    pad = int(min(w, h) * 0.005)
    top = max(0, top - pad)
    bottom = min(h, bottom + pad)
    left = max(0, left - pad)
    right = min(w, right + pad)

    gw = right - left
    gh = bottom - top
    final_aspect = gw / gh if gh > 0 else 0

    print(f"Auto-detected grid: ({left}, {top}) to ({right}, {bottom}) — {gw}x{gh}px, aspect={final_aspect:.2f}")
    return (left, top, right, bottom)


def crop_puzzle_grid(input_pdf_path):
    """Crop the puzzle grid from the page, render to image, and create a clean PDF."""
    reader = PdfReader(input_pdf_path)
    page = reader.pages[0]
    page_width = float(page.mediabox.width)
    page_height = float(page.mediabox.height)
    print(f"Original page: {page_width:.0f} x {page_height:.0f} points")

    # Render the full page at high DPI
    images = convert_from_path(input_pdf_path, dpi=300, first_page=1, last_page=1)
    img = images[0]
    img_width, img_height = img.size

    # Try auto-detection first
    bounds = find_grid_bounds(img)

    if bounds:
        left, top, right, bottom = bounds
    else:
        # Fallback: generous center crop
        left = int(img_width * 0.05)
        top = int(img_height * 0.05)
        right = int(img_width * 0.95)
        bottom = int(img_height * 0.55)

    grid_img = img.crop((left, top, right, bottom))
    print(f"Grid image: {grid_img.size[0]} x {grid_img.size[1]} pixels")

    # Save cropped grid as temp file
    import tempfile
    tmp_img = tempfile.NamedTemporaryFile(suffix='.png', delete=False)
    grid_img.save(tmp_img.name, format='PNG', dpi=(300, 300))

    # Create a PDF page with the grid image scaled to fill letter size
    pdf_buffer = BytesIO()
    letter_width, letter_height = letter
    margin = 0.3 * inch
    avail_width = letter_width - 2 * margin
    avail_height = letter_height - 2 * margin

    grid_aspect = grid_img.size[0] / grid_img.size[1]
    avail_aspect = avail_width / avail_height

    if grid_aspect > avail_aspect:
        display_width = avail_width
        display_height = avail_width / grid_aspect
    else:
        display_height = avail_height
        display_width = avail_height * grid_aspect

    from reportlab.pdfgen import canvas
    c = canvas.Canvas(pdf_buffer, pagesize=letter)

    # Center the grid on the page
    x = (letter_width - display_width) / 2
    y = (letter_height - display_height) / 2

    c.drawImage(tmp_img.name, x, y, display_width, display_height)
    c.save()

    import os
    os.unlink(tmp_img.name)

    return pdf_buffer.getvalue()


def _build_clue_sheet(across_clues, down_clues, title="", blurb="",
                      font_size=8.5, leading=10.5, margin=0.4,
                      col_width=2.5, num_cols=3):
    """Build a clue sheet PDF with the given typesetting parameters.

    Returns (pdf_bytes, num_pages).
    """
    buffer = BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=letter,
        leftMargin=margin * inch,
        rightMargin=margin * inch,
        topMargin=margin * inch,
        bottomMargin=(margin - 0.1) * inch,
    )

    title_style = ParagraphStyle(
        'ClueTitle',
        fontSize=13,
        fontName='Helvetica-Bold',
        spaceAfter=6,
        leading=15,
    )

    section_style = ParagraphStyle(
        'SectionHeader',
        fontSize=10,
        fontName='Helvetica-Bold',
        spaceBefore=8,
        spaceAfter=3,
    )

    clue_style = ParagraphStyle(
        'Clue',
        fontSize=font_size,
        leading=leading,
        fontName='Helvetica',
    )

    blurb_style = ParagraphStyle(
        'Blurb',
        fontSize=8,
        leading=10,
        fontName='Helvetica-Oblique',
        textColor=colors.HexColor('#444444'),
        spaceAfter=6,
    )

    elements = []

    if title:
        elements.append(Paragraph(title, title_style))
    if blurb:
        safe = blurb.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        elements.append(Paragraph(safe, blurb_style))

    def make_clue_table(clues, header_text):
        """Flow the clues down independent columns.

        WHY NOT A TABLE (fixed 2026-09-27). This used to chunk the clues into
        num_cols equal-count lists and render row i as [col0[i], col1[i], col2[i]].
        A reportlab Table row is as tall as its TALLEST cell, so a long clue in one
        column pushed blank space into the others at the same index -- the clues were
        coupled by nothing but their position in the list. On the 09-27 puzzle, clue 7
        ("Shoot for dinner?", one line) sat opposite clue 49 (the five-line Coriolis
        clue), so column 1 rendered one line of text and four lines of nothing. xian
        reported it twice as "odd gaps between across clues 7 and 12"; I twice assumed
        it was the source typesetting and did not look at my own output.

        BalancedColumns flows the clues continuously and balances by height, so a long
        clue lengthens only its own column, and it paginates properly -- which a
        single-row table would not.
        """
        elements.append(Paragraph(header_text, section_style))
        flowables = [Paragraph(f"<b>{num}</b> {clue}", clue_style) for num, clue in clues]
        elements.append(
            BalancedColumns(
                flowables,
                nCols=num_cols,
                needed=72,
                innerPadding=6,
                endSlack=0.2,
            )
        )

    make_clue_table(across_clues, "ACROSS")
    make_clue_table(down_clues, "DOWN")

    doc.build(elements)
    pdf_bytes = buffer.getvalue()

    # Count pages
    from pypdf import PdfReader as _PdfReader
    page_count = len(_PdfReader(BytesIO(pdf_bytes)).pages)

    return pdf_bytes, page_count


def create_clue_sheet(across_clues, down_clues, title="", blurb=""):
    """Create a compact clue sheet PDF with readable text.

    Uses an adaptive approach: tries the preferred layout first (8.5pt, 3-col),
    then falls back to tighter settings if the clues overflow to multiple pages.
    The optional title/blurb are included as long as they still fit on one
    page; if the blurb would force a second page even at the tightest layout,
    it is dropped so the clues stay on a single sheet.
    """
    configs = [
        # Preferred: readable size
        {"font_size": 8.5, "leading": 10.5, "margin": 0.4, "col_width": 2.5, "num_cols": 3},
        # Fallback 1: tighter leading and margins
        {"font_size": 7.5, "leading": 9.0, "margin": 0.3, "col_width": 2.5, "num_cols": 3},
        # Fallback 2: 4 columns, smaller font
        {"font_size": 7.0, "leading": 8.5, "margin": 0.3, "col_width": 1.9, "num_cols": 4},
    ]

    # Prefer including the blurb; if nothing fits with it, retry without it.
    last_bytes = last_pages = None
    for use_blurb in ((True, False) if blurb else (False,)):
        b = blurb if use_blurb else ""
        for cfg in configs:
            pdf_bytes, pages = _build_clue_sheet(
                across_clues, down_clues, title=title, blurb=b, **cfg)
            desc = (f"{cfg['num_cols']}col {cfg['font_size']}pt/{cfg['leading']}pt"
                    f"{' +blurb' if use_blurb else ''}")
            if pages == 1:
                print(f"Clue layout: {desc} — fits on 1 page")
                return pdf_bytes
            print(f"Clue layout: {desc} — {pages} pages (overflow), trying tighter...")
            last_bytes, last_pages = pdf_bytes, pages
        if use_blurb:
            print("Blurb would force a second page — dropping it to keep clues on one sheet")

    # If nothing fits on 1 page, use the last (tightest) config
    print(f"WARNING: Clues overflow even at tightest layout ({last_pages} pages)")
    return last_bytes


def check_clue_coverage(across, down):
    """Detect dropped or merged clues via the numbering invariant.

    2026-09-13 (xian's report from the 09-06 puzzle): some clues were IMAGES,
    which extract_text() silently drops — the clue's number then had no text,
    and the parser merged it with the next clue. The workaround was manual.

    The detector is stronger than looking for 'empty' clues, which the merge
    erases: crossword numbering guarantees every integer 1..max starts an
    ACROSS or DOWN entry, so a dropped/merged clue ALWAYS leaves a hole in
    the union of parsed numbers. Returns the sorted list of missing numbers
    (empty = clean).
    """
    nums = {n for n, _ in (across or [])} | {n for n, _ in (down or [])}
    if not nums:
        return []
    return [n for n in range(1, max(nums) + 1) if n not in nums]


def page_has_images(pdf_path):
    """Corroborating signal: does the source page embed raster images
    (XObject /Image)? Text-only puzzle pages normally don't."""
    try:
        page = PdfReader(pdf_path).pages[0]
        xobjs = page.get('/Resources', {}).get('/XObject', {})
        return any(x.get_object().get('/Subtype') == '/Image' for x in xobjs.values())
    except Exception:
        return False


def combine_pdfs(grid_pdf_bytes, clue_pdf_bytes, output_path):
    """Combine the grid page and clue page into one PDF."""
    writer = PdfWriter()

    grid_reader = PdfReader(BytesIO(grid_pdf_bytes))
    writer.add_page(grid_reader.pages[0])

    clue_reader = PdfReader(BytesIO(clue_pdf_bytes))
    for page in clue_reader.pages:
        writer.add_page(page)

    with open(output_path, 'wb') as f:
        writer.write(f)
    print(f"Output: {output_path} ({len(writer.pages)} pages)")


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} input.pdf output.pdf [title]")
        sys.exit(1)

    input_pdf = sys.argv[1]
    output_pdf = sys.argv[2]
    # Optional clean title from the caller (e.g. the NYT metadata JSON), which
    # beats the letterspaced title the PDF text layer mangles.
    title_override = sys.argv[3].strip() if len(sys.argv) > 3 else ""

    print(f"Processing magazine-page Sunday crossword: {input_pdf}")

    # Extract clues
    print("Extracting clues...")
    across, down, title, blurb = extract_clues(input_pdf)
    if title_override:
        title = title_override
    if across:
        print(f"  Found {len(across)} ACROSS clues, {len(down)} DOWN clues")
        across_nums = [c[0] for c in across]
        down_nums = [c[0] for c in down]
        print(f"  ACROSS range: {min(across_nums)}-{max(across_nums)}")
        print(f"  DOWN range: {min(down_nums)}-{max(down_nums)}")
    else:
        print("  WARNING: Could not parse clues")

    # Crop and enlarge the puzzle grid
    print("Cropping puzzle grid...")
    grid_pdf = crop_puzzle_grid(input_pdf)

    # Image-clue safety net (see check_clue_coverage docstring): holes in the
    # numbering mean clues were dropped/merged — most likely image clues the
    # text layer can't carry. Never ship a silently incomplete clue sheet:
    # warn with the exact numbers, and append the ORIGINAL page so the human
    # has the pictures the pipeline couldn't.
    missing = check_clue_coverage(across, down)
    append_original = False
    if missing:
        imgs = page_has_images(input_pdf)
        print(f"WARNING: clue numbers missing from parsed set: {missing} — "
              f"clues were dropped or merged (image clues?{' page DOES embed raster images' if imgs else ' no raster images found — cause unclear'}). "
              f"Appending the original page so nothing is lost.")
        append_original = True

    # Create formatted clue sheet
    if across and down:
        print(f"Creating clue sheet (title: '{title}', blurb: {len(blurb)} chars)...")
        clue_pdf = create_clue_sheet(across, down, title=title, blurb=blurb)
        print("Combining grid + clue sheet...")
        combine_pdfs(grid_pdf, clue_pdf, output_pdf)
    else:
        with open(output_pdf, 'wb') as f:
            f.write(grid_pdf)

    if append_original:
        writer = PdfWriter()
        for p in PdfReader(output_pdf).pages:
            writer.add_page(p)
        writer.add_page(PdfReader(input_pdf).pages[0])
        with open(output_pdf, 'wb') as f:
            writer.write(f)
        print(f"Appended original page — output is now {len(writer.pages)} pages "
              f"(last page is the untouched source, for the clues we couldn't extract).")

    print("Done!")


if __name__ == '__main__':
    main()
