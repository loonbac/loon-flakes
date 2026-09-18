import assert from "node:assert/strict";
import test from "node:test";
import { hasTerminalImage, trimTranscriptFrameBody } from "./image-layout.ts";

const blank = (line: string) => line.trim() === "";

test("keeps Kitty rows reserved after the graphics command", () => {
	const image = "    \x1b_Ga=T,f=100,C=1,c=32,r=4,i=7;AAAA\x1b\\";
	const body = trimTranscriptFrameBody(["", "Read image file", image, "", "", "", "", ""], blank);
	assert.equal(hasTerminalImage(image), true);
	assert.deepEqual(body, ["Read image file", image, "", "", ""]);
});

test("keeps the complete 20-row Kitty footprint used by transcript images", () => {
	const image = "  \x1b_Ga=T,f=100,q=2,C=1,c=64,r=20,i=9;AAAA\x1b\\";
	const rendered = ["", "Read image file [image/png]", image, ...Array.from({ length: 19 }, () => ""), ""];
	const body = trimTranscriptFrameBody(rendered, blank);
	assert.equal(body.length, 21);
	assert.equal(body[0], "Read image file [image/png]");
	assert.equal(body[1], image);
	assert.equal(body.at(-1), "");
});

test("keeps iTerm2 rows reserved before its cursor-up command", () => {
	const image = "\x1b[3A\x1b]1337;File=inline=1;width=32;height=auto:AAAA\x07";
	const body = trimTranscriptFrameBody(["", "", "", image, "", ""], blank);
	assert.equal(hasTerminalImage(image), true);
	assert.deepEqual(body, ["", "", "", image]);
});

test("terminal image detection is stable across repeated renders", () => {
	const image = "\x1b_Ga=T,f=100,C=1,c=32,r=2,i=7;AAAA\x1b\\";
	assert.equal(hasTerminalImage(image), true);
	assert.equal(hasTerminalImage(image), true);
	assert.equal(hasTerminalImage(image), true);
});

test("continues trimming ordinary transcript padding", () => {
	assert.deepEqual(trimTranscriptFrameBody(["", "", "result", "", ""], blank), ["result"]);
});
