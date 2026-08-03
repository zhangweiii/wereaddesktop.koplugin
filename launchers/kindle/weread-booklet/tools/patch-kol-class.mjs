#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const root = process.argv[2];
if (!root) {
    console.error("usage: node patch-kol-class.mjs <unpacked-jar-root>");
    process.exit(2);
}

const replacements = [
    ["/mnt/us/documents/KOReader.kol", "/mnt/us/documents/微信读书.weread"],
    ["KOReader", "微信读书"],
    ["/var/tmp/KOL.log", "/var/tmp/weread-launcher.log"],
    ["KOL: ", "WeRead: "],
];

const targets = [
    "com/mobileread/ixtab/kolauncher/KualBooklet.class",
    "com/mobileread/ixtab/kolauncher/resources/KualLog.class",
];

const counts = new Map(replacements.map(([from]) => [from, 0]));

function u2(buffer, offset) {
    return buffer.readUInt16BE(offset);
}

function patchClass(filename) {
    const input = fs.readFileSync(filename);
    if (input.readUInt32BE(0) !== 0xcafebabe) {
        throw new Error(`${filename}: not a Java class file`);
    }

    const constantPoolCount = u2(input, 8);
    const chunks = [input.subarray(0, 10)];
    let offset = 10;

    for (let index = 1; index < constantPoolCount; index += 1) {
        const start = offset;
        const tag = input[offset];
        offset += 1;

        if (tag === 1) {
            const length = u2(input, offset);
            const valueStart = offset + 2;
            const valueEnd = valueStart + length;
            let value = input.subarray(valueStart, valueEnd).toString("utf8");

            for (const [from, to] of replacements) {
                if (value.includes(from)) {
                    const matches = value.split(from).length - 1;
                    counts.set(from, counts.get(from) + matches);
                    value = value.split(from).join(to);
                }
            }

            const encoded = Buffer.from(value, "utf8");
            if (encoded.length > 0xffff) {
                throw new Error(`${filename}: patched UTF-8 constant is too long`);
            }
            const entry = Buffer.allocUnsafe(3 + encoded.length);
            entry[0] = tag;
            entry.writeUInt16BE(encoded.length, 1);
            encoded.copy(entry, 3);
            chunks.push(entry);
            offset = valueEnd;
            continue;
        }

        const sizes = new Map([
            [3, 4], [4, 4], [5, 8], [6, 8], [7, 2], [8, 2],
            [9, 4], [10, 4], [11, 4], [12, 4], [15, 3], [16, 2],
            [17, 4], [18, 4], [19, 2], [20, 2],
        ]);
        const size = sizes.get(tag);
        if (size === undefined) {
            throw new Error(`${filename}: unsupported constant-pool tag ${tag}`);
        }
        offset += size;
        chunks.push(input.subarray(start, offset));
        if (tag === 5 || tag === 6) {
            index += 1;
        }
    }

    chunks.push(input.subarray(offset));
    fs.writeFileSync(filename, Buffer.concat(chunks));
}

for (const relative of targets) {
    const filename = path.join(root, relative);
    if (!fs.existsSync(filename)) {
        throw new Error(`missing expected KOL class: ${relative}`);
    }
    patchClass(filename);
}

for (const [from] of replacements) {
    if (counts.get(from) === 0) {
        throw new Error(`expected KOL constant not found: ${from}`);
    }
}

for (const [from, to] of replacements) {
    console.log(`${JSON.stringify(from)} -> ${JSON.stringify(to)} (${counts.get(from)})`);
}
