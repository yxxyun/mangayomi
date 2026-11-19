import 'package:flutter/foundation.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:mangayomi/utils/log/log.dart';

/// What every extension runtime gets, Mangayomi and LNReader alike: console
/// output routed to the app log, and the Kotlin-style substring helpers.
void registerJsCommon(JavascriptRuntime runtime) {
  runtime.onMessage('log', (dynamic args) {
    if (kDebugMode || useLogger) {
      // ignore: avoid_print
      print("LoggerLevel.warning:${args[0]}");
      Logger.add(LoggerLevel.warning, "${args[0]}");
    }
    return null;
  });

  runtime.evaluate('''
console.log = function (message) {
    if (typeof message === "object") {
         message = JSON.stringify(message);
      }
    sendMessage("log", JSON.stringify([message.toString()]));
};
console.warn = function (message) {
    if (typeof message === "object") {
         message = JSON.stringify(message);
      }
    sendMessage("log", JSON.stringify([message.toString()]));
};
console.error = function (message) {
    if (typeof message === "object") {
         message = JSON.stringify(message);
      }
    sendMessage("log", JSON.stringify([message.toString()]));
};
String.prototype.substringAfter = function(pattern) {
    const startIndex = this.indexOf(pattern);
    if (startIndex === -1) return this.substring(0);

    const start = startIndex + pattern.length;
    return this.substring(start);
}

String.prototype.substringAfterLast = function(pattern) {
    return this.split(pattern).pop();
}

String.prototype.substringBefore = function(pattern) {
    const endIndex = this.indexOf(pattern);
    if (endIndex === -1) return this.substring(0);

    return this.substring(0, endIndex);
}

String.prototype.substringBeforeLast = function(pattern) {
    const endIndex = this.lastIndexOf(pattern);
    if (endIndex === -1) return this.substring(0);
    return this.substring(0, endIndex);
}

String.prototype.substringBetween = function(left, right) {
    let startIndex = 0;
    let index = this.indexOf(left, startIndex);
    if (index === -1) return "";
    let leftIndex = index + left.length;
    let rightIndex = this.indexOf(right, leftIndex);
    if (rightIndex === -1) return "";
    startIndex = rightIndex + right.length;
    return this.substring(leftIndex, rightIndex);
}
''');

  _registerJsHtmlAndEncoding(runtime);
}

/// An HTML parser and the encoding helpers, for sources ported from runtimes
/// where those came for free.
///
/// A source written for another app often walks a plain node tree
/// (`{tag, attrs, children, text}`) instead of using CSS selectors, and reaches
/// for utf8/base64 helpers the host used to provide. Rather than make every
/// such port carry its own copy, the runtime offers them once:
///
///   var root = parseHtmlTree(body);
///   var links = htmlNodes(root, tagged("a"));
///   htmlAttr(links[0], "href");  htmlClass(links[0], "thumb");
///   htmlText(links[0]);
///
/// Text nodes carry no `tag` and live in `children`, parents are linked, and
/// `htmlText` collapses whitespace the same way.
void _registerJsHtmlAndEncoding(JavascriptRuntime runtime) {
  runtime.evaluate(r'''
var __mgVoidTags = ["area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr"];
var __mgRawTags = ["script", "style", "textarea", "title"];

function decodeHtmlEntities(text) {
    if (text.indexOf("&") === -1) return text;
    var named = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: "\u00a0" };
    return text.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, function (entity, body) {
        if (body[0] === "#") {
            var code = body[1] === "x" || body[1] === "X"
                ? parseInt(body.slice(2), 16)
                : parseInt(body.slice(1), 10);
            return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
        }
        return Object.prototype.hasOwnProperty.call(named, body) ? named[body] : entity;
    });
}

function __mgFindTagEnd(text, from) {
    var quote = "";
    for (var index = from; index < text.length; index++) {
        var character = text[index];
        if (quote !== "") {
            if (character === quote) quote = "";
        } else if (character === "\"" || character === "'") {
            quote = character;
        } else if (character === ">") {
            return index;
        }
    }
    return -1;
}

function __mgParseAttrs(text) {
    var attrs = {};
    var pattern = /([^\s=\/>]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]*))?/g;
    var match;
    while ((match = pattern.exec(text)) !== null) {
        var name = match[1].toLowerCase();
        var value = match[2] === undefined ? "" : match[2];
        if (value[0] === "\"" || value[0] === "'") value = value.slice(1, -1);
        attrs[name] = decodeHtmlEntities(value);
    }
    return attrs;
}

/// Parses [text] into a node tree: { tag, attrs, children, parent, text },
/// where a text node has no tag.
function parseHtmlTree(text) {
    text = String(text || "");
    var root = { tag: "#document", attrs: {}, children: [] };
    var stack = [root];
    var push = function (node) {
        var parent = stack[stack.length - 1];
        node.parent = parent;
        parent.children.push(node);
    };
    var index = 0;
    while (index < text.length) {
        var lt = text.indexOf("<", index);
        if (lt < 0) {
            var tail = text.slice(index);
            if (tail !== "") push({ tag: undefined, text: decodeHtmlEntities(tail) });
            break;
        }
        if (lt > index) {
            push({ tag: undefined, text: decodeHtmlEntities(text.slice(index, lt)) });
        }
        if (text.startsWith("<!--", lt)) {
            var commentEnd = text.indexOf("-->", lt + 4);
            index = commentEnd < 0 ? text.length : commentEnd + 3;
            continue;
        }
        if (text.startsWith("<!", lt) || text.startsWith("<?", lt)) {
            var declEnd = text.indexOf(">", lt);
            index = declEnd < 0 ? text.length : declEnd + 1;
            continue;
        }
        var gt = __mgFindTagEnd(text, lt + 1);
        if (gt < 0) {
            push({ tag: undefined, text: decodeHtmlEntities(text.slice(lt)) });
            break;
        }
        var raw = text.slice(lt + 1, gt);
        index = gt + 1;
        if (raw[0] === "/") {
            var closeName = raw.slice(1).trim().toLowerCase();
            for (var depth = stack.length - 1; depth > 0; depth--) {
                if (stack[depth].tag === closeName) {
                    stack.length = depth;
                    break;
                }
            }
            continue;
        }
        var nameMatch = /^([a-zA-Z][^\s\/>]*)/.exec(raw);
        if (!nameMatch) continue;
        var tag = nameMatch[1].toLowerCase();
        var node = { tag: tag, attrs: __mgParseAttrs(raw.slice(nameMatch[0].length)), children: [] };
        push(node);
        if (__mgVoidTags.indexOf(tag) !== -1 || /\/\s*$/.test(raw)) continue;
        if (__mgRawTags.indexOf(tag) !== -1) {
            var rawClose = text.toLowerCase().indexOf("</" + tag, index);
            var rawEnd = rawClose < 0 ? text.length : rawClose;
            var inner = text.slice(index, rawEnd);
            if (inner !== "") {
                var textNode = { tag: undefined, text: inner };
                textNode.parent = node;
                node.children.push(textNode);
            }
            index = rawEnd;
            continue;
        }
        stack.push(node);
    }
    return root;
}

/// Every node under [root] (and [root] itself) for which [match] is true.
function htmlNodes(root, match) {
    var found = [];
    if (!root) return found;
    var pending = [root];
    while (pending.length > 0) {
        var node = pending.pop();
        if (match(node)) found.push(node);
        var children = node.children || [];
        for (var i = children.length - 1; i >= 0; i--) {
            pending.push(children[i]);
        }
    }
    return found;
}

function htmlAttr(node, name) {
    return node && node.attrs && typeof node.attrs[name] === "string" ? node.attrs[name] : "";
}

function htmlClass(node, name) {
    return htmlAttr(node, "class").split(/\s+/).indexOf(name) !== -1;
}

function htmlFirstClass(root, name) {
    return htmlNodes(root, function (node) { return htmlClass(node, name); })[0] || null;
}

function htmlText(root) {
    var parts = [];
    var textNodes = htmlNodes(root, function (node) {
        return node.tag === undefined && typeof node.text === "string";
    });
    for (var i = 0; i < textNodes.length; i++) {
        var node = textNodes[i];
        if (node.parent && (node.parent.tag === "script" || node.parent.tag === "style")) continue;
        parts.push(node.text);
    }
    return parts.join(" ").split(/\s+/).filter(function (part) { return part !== ""; }).join(" ");
}

function tagged(name) {
    return function (node) { return node.tag === name; };
}

/// UTF-8 bytes of [text].
function utf8Encode(text) {
    var bytes = [];
    var characters = Array.from(String(text || ""));
    for (var i = 0; i < characters.length; i++) {
        var code = characters[i].codePointAt(0);
        if (code < 0x80) {
            bytes.push(code);
        } else if (code < 0x800) {
            bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
        } else if (code < 0x10000) {
            bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
        } else {
            bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
                0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
        }
    }
    return bytes;
}

/// Decodes UTF-8 [bytes] (an array of numbers) back to a string.
function utf8Decode(bytes) {
    var text = "";
    var i = 0;
    while (i < bytes.length) {
        var first = bytes[i] & 0xff;
        if (first < 0x80) {
            text += String.fromCharCode(first);
            i += 1;
        } else if ((first & 0xe0) === 0xc0 && i + 1 < bytes.length) {
            text += String.fromCharCode(((first & 0x1f) << 6) | (bytes[i + 1] & 0x3f));
            i += 2;
        } else if ((first & 0xf0) === 0xe0 && i + 2 < bytes.length) {
            text += String.fromCharCode(((first & 0x0f) << 12) |
                ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f));
            i += 3;
        } else if ((first & 0xf8) === 0xf0 && i + 3 < bytes.length) {
            var code = ((first & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) |
                ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
            text += String.fromCodePoint(code);
            i += 4;
        } else {
            text += String.fromCharCode(first);
            i += 1;
        }
    }
    return text;
}

var __mgBase64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// The bytes [text] encodes to, base64.
function base64Decode(text) {
    var clean = String(text || "").replace(/[^A-Za-z0-9+/=]/g, "");
    var bytes = [];
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < clean.length; i++) {
        if (clean[i] === "=") break;
        var value = __mgBase64Alphabet.indexOf(clean[i]);
        if (value < 0) continue;
        buffer = (buffer << 6) | value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            bytes.push((buffer >> bits) & 0xff);
        }
    }
    return bytes;
}

/// [bytes] (an array of numbers) as base64.
function base64Encode(bytes) {
    var output = "";
    var i = 0;
    for (; i + 2 < bytes.length; i += 3) {
        var chunk = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
        output += __mgBase64Alphabet[(chunk >> 18) & 0x3f] + __mgBase64Alphabet[(chunk >> 12) & 0x3f] +
            __mgBase64Alphabet[(chunk >> 6) & 0x3f] + __mgBase64Alphabet[chunk & 0x3f];
    }
    var remaining = bytes.length - i;
    if (remaining === 1) {
        var one = bytes[i] << 16;
        output += __mgBase64Alphabet[(one >> 18) & 0x3f] + __mgBase64Alphabet[(one >> 12) & 0x3f] + "==";
    } else if (remaining === 2) {
        var two = (bytes[i] << 16) | (bytes[i + 1] << 8);
        output += __mgBase64Alphabet[(two >> 18) & 0x3f] + __mgBase64Alphabet[(two >> 12) & 0x3f] +
            __mgBase64Alphabet[(two >> 6) & 0x3f] + "=";
    }
    return output;
}

/// Lowercase hex of [bytes] (an array of numbers).
function hexEncode(bytes) {
    var output = "";
    for (var i = 0; i < bytes.length; i++) {
        var value = bytes[i] & 0xff;
        output += (value < 16 ? "0" : "") + value.toString(16);
    }
    return output;
}

/// [count] random bytes. Math.random is not a cryptographic source; it is what
/// a source needs for a per-install identifier or a UUID v4.
function randomBytes(count) {
    var bytes = [];
    for (var i = 0; i < count; i++) {
        bytes.push(Math.floor(Math.random() * 256));
    }
    return bytes;
}
''');
}
