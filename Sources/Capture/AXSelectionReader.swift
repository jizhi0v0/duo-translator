import AppKit
import ApplicationServices

enum AXSelectionReader {
    /// Read the selected text of the currently focused UI element.
    static func selectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        // CFTypeRef with verified type id — this force-cast is safe.
        let element = focusedRef as! AXUIElement

        if let text = stringAttribute(of: element, kAXSelectedTextAttribute), !text.isEmpty {
            return text
        }

        // WebKit sometimes only exposes the selection through the range +
        // parameterized string pair.
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
            let rangeRef,
            CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            // CFTypeRef with verified type id — this force-cast is safe.
            let rangeValue = rangeRef as! AXValue
            if let text = stringForSelectedRange(of: element, rangeValue), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// The AX selection range is in UTF-16 units and can split a surrogate
    /// pair, which bridges the orphan unit as U+FFFD. Repair by re-reading
    /// with the range aligned to composed-character boundaries.
    private static func stringForSelectedRange(of element: AXUIElement, _ rangeValue: AXValue) -> String? {
        guard let text = parameterizedString(of: element, rangeValue) else { return nil }
        guard CapturedTextSanitizer.containsReplacementCharacter(text) else { return text }

        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &cfRange) else { return text }
        let range = NSRange(location: cfRange.location, length: cfRange.length)

        // Best repair: substring the element's full value ourselves with the
        // range widened to character boundaries. WebKit web areas often have
        // no AXValue, so this is opportunistic.
        if let full = stringAttribute(of: element, kAXValueAttribute),
           let aligned = CapturedTextSanitizer.alignedRange(range, in: full) {
            let repaired = (full as NSString).substring(with: aligned)
            if !CapturedTextSanitizer.containsReplacementCharacter(repaired) {
                return repaired
            }
        }

        // Otherwise widen the raw range by one UTF-16 unit on each side that
        // shows the damage, so a split pair at that edge becomes whole.
        let leading = text.unicodeScalars.first?.value == 0xFFFD ? min(cfRange.location, 1) : 0
        let trailing = text.unicodeScalars.last?.value == 0xFFFD ? 1 : 0
        guard leading + trailing > 0 else { return text }
        var widened = CFRange(
            location: cfRange.location - leading,
            length: cfRange.length + leading + CFIndex(trailing)
        )
        if let widenedValue = AXValueCreate(.cfRange, &widened),
           let retried = parameterizedString(of: element, widenedValue),
           !CapturedTextSanitizer.containsReplacementCharacter(retried) {
            return retried
        }
        return text
    }

    private static func parameterizedString(of element: AXUIElement, _ rangeValue: AXValue) -> String? {
        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringRef
        ) == .success else { return nil }
        return stringRef as? String
    }

    /// Chromium (and most Electron apps) only build their accessibility tree
    /// once this app-level attribute is set. Call, wait ~100ms, retry.
    static func pokeManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func stringAttribute(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
