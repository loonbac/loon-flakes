const KITTY_GRAPHICS_RE = /\x1b_G[\s\S]*?\x1b\\/u;
const ITERM_IMAGE_RE = /\x1b\]1337;File=[^\x07]*\x07/u;

function terminalImageRows(line: string): { rows: number; protocol: "kitty" | "iterm2" } | undefined {
	const kittyControls = /\x1b_G([^;]*);/u.exec(line)?.[1];
	const kittyRows = kittyControls === undefined
		? undefined
		: /(?:^|,)r=(\d+)(?:,|$)/u.exec(kittyControls)?.[1];
	if (kittyRows !== undefined) {
		return { rows: Math.max(1, Number.parseInt(kittyRows, 10)), protocol: "kitty" };
	}

	if (!ITERM_IMAGE_RE.test(line)) return undefined;
	// Pi renders iTerm2 images with `height=auto`; the preceding cursor-up
	// sequence is the authoritative reservation: offset = rows - 1.
	const cursorOffset = /\x1b\[(\d+)A(?=[\s\S]*\x1b\]1337;File=)/u.exec(line)?.[1];
	if (cursorOffset !== undefined) {
		return { rows: Number.parseInt(cursorOffset, 10) + 1, protocol: "iterm2" };
	}
	const explicitRows = /\x1b\]1337;File=[^:\x07]*\bheight=(\d+)[^:\x07]*:/u.exec(line)?.[1];
	return {
		rows: explicitRows === undefined ? 1 : Math.max(1, Number.parseInt(explicitRows, 10)),
		protocol: "iterm2",
	};
}

export function hasTerminalImage(line: string): boolean {
	return KITTY_GRAPHICS_RE.test(line) || ITERM_IMAGE_RE.test(line);
}

/**
 * Trim ornamental whitespace without deleting rows reserved by terminal image
 * protocols. Kitty emits the image command first and blank rows after it;
 * iTerm2 emits blank rows first and the cursor-up image command last. Those
 * apparently empty rows are layout, not padding.
 */
export function trimTranscriptFrameBody(
	lines: string[],
	isWhitespace: (line: string) => boolean,
): string[] {
	let protectedStart = lines.length;
	let protectedEnd = 0;
	for (let index = 0; index < lines.length; index++) {
		const image = terminalImageRows(lines[index]!);
		if (!image) continue;
		const start = image.protocol === "kitty" ? index : Math.max(0, index - image.rows + 1);
		const end = image.protocol === "kitty" ? Math.min(lines.length, index + image.rows) : index + 1;
		protectedStart = Math.min(protectedStart, start);
		protectedEnd = Math.max(protectedEnd, end);
	}

	let first = 0;
	let last = lines.length;
	while (first < last && first < protectedStart && isWhitespace(lines[first]!)) first++;
	while (last > first && last > protectedEnd && isWhitespace(lines[last - 1]!)) last--;
	return lines.slice(first, last);
}
