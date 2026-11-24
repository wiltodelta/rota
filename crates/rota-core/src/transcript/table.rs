#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnAlignment {
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownTable {
    pub headers: Vec<String>,
    pub alignments: Vec<ColumnAlignment>,
    pub rows: Vec<Vec<String>>,
}

impl MarkdownTable {
    pub fn parse(lines: &[&str], index: &mut usize) -> Option<Self> {
        if *index + 1 >= lines.len() {
            return None;
        }
        let headers = Self::cells(lines[*index])?;
        let alignments = Self::delimiter(lines[*index + 1])?;
        if headers.len() != alignments.len() {
            return None;
        }
        *index += 2;
        let mut rows = Vec::new();
        while *index < lines.len() {
            let Some(mut row_cells) = Self::cells(lines[*index]) else {
                break;
            };
            row_cells.resize(headers.len(), String::new());
            rows.push(row_cells);
            *index += 1;
        }
        *index -= 1;
        Some(Self {
            headers,
            alignments,
            rows,
        })
    }

    pub fn cells(line: &str) -> Option<Vec<String>> {
        let source = line.trim();
        let mut cells = Vec::new();
        let mut cell = String::new();
        let mut escaped = false;
        let mut separators = 0usize;

        for ch in source.chars() {
            if escaped {
                if ch != '|' {
                    cell.push('\\');
                }
                cell.push(ch);
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '|' {
                cells.push(cell.trim().to_string());
                cell.clear();
                separators += 1;
            } else {
                cell.push(ch);
            }
        }
        if escaped {
            cell.push('\\');
        }
        if separators == 0 {
            return None;
        }
        let trailing_empty = cell.trim().is_empty();
        cells.push(cell.trim().to_string());
        if source.starts_with('|') && !cells.is_empty() {
            cells.remove(0);
        }
        if trailing_empty && source.ends_with('|') && !cells.is_empty() {
            cells.pop();
        }
        (!cells.is_empty()).then_some(cells)
    }

    pub fn delimiter(line: &str) -> Option<Vec<ColumnAlignment>> {
        let cells = Self::cells(line)?;
        let mut out = Vec::with_capacity(cells.len());
        for cell in cells {
            let dashes = cell.trim_matches(':');
            if dashes.is_empty() || !dashes.chars().all(|c| c == '-') {
                return None;
            }
            let align = match (cell.starts_with(':'), cell.ends_with(':')) {
                (true, true) => ColumnAlignment::Center,
                (false, true) => ColumnAlignment::Right,
                _ => ColumnAlignment::Left,
            };
            out.push(align);
        }
        Some(out)
    }
}
