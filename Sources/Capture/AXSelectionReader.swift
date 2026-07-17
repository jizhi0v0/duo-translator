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
            var stringRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeRef,
                &stringRef
            ) == .success,
                let text = stringRef as? String,
                !text.isEmpty {
                return text
            }
        }
        return nil
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
