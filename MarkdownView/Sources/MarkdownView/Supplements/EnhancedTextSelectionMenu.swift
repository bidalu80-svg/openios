#if canImport(UIKit) && os(iOS) && !os(tvOS) && !os(watchOS)

import Foundation
import Litext
import ObjectiveC
import UIKit

private let textSelectionActionNotificationName = Notification.Name("com.openui.textSelection.actionRequested")

enum EnhancedTextSelectionAction: String, CaseIterable {
    case ask
    case lookUp
    case searchWeb

    var title: String {
        switch self {
        case .ask:
            "询问 Iexa"
        case .lookUp:
            "查询"
        case .searchWeb:
            "搜索网页"
        }
    }

    var selector: Selector {
        switch self {
        case .ask:
            #selector(LTXLabel.iexaAskSelectedText)
        case .lookUp:
            #selector(LTXLabel.iexaLookUpSelectedText)
        case .searchWeb:
            #selector(LTXLabel.iexaSearchSelectedTextOnWeb)
        }
    }
}

enum EnhancedTextSelectionMenu {
    private static var didInstall = false

    static func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true

        swizzle(
            cls: UIMenuController.self,
            original: #selector(UIMenuController.showMenu(from:rect:)),
            replacement: #selector(UIMenuController.iexa_showMenu(from:rect:))
        )
        swizzle(
            cls: UIMenuController.self,
            original: #selector(setter: UIMenuController.menuItems),
            replacement: #selector(UIMenuController.iexa_setMenuItems(_:))
        )
        swizzle(
            cls: LTXLabel.self,
            original: #selector(LTXLabel.canPerformAction(_:withSender:)),
            replacement: #selector(LTXLabel.iexa_canPerformAction(_:withSender:))
        )
    }

    static func isEnhancedAction(_ selector: Selector) -> Bool {
        EnhancedTextSelectionAction.allCases.contains { $0.selector == selector }
    }

    static func selectedText(from label: LTXLabel) -> String? {
        guard let range = label.selectionRange,
              range.location != NSNotFound,
              range.length > 0,
              label.attributedText.length > 0,
              range.location < label.attributedText.length else {
            return nil
        }

        let safeRange = NSRange(
            location: range.location,
            length: min(range.length, label.attributedText.length - range.location)
        )
        let text = label.attributedText
            .attributedSubstring(from: safeRange)
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func augmentCurrentMenu() {
        let menuController = UIMenuController.shared
        menuController.menuItems = augmentedMenuItems(from: menuController.menuItems)
    }

    static func shouldAugmentMenuItems(_ items: [UIMenuItem]?) -> Bool {
        guard let items, !items.isEmpty else { return false }
        let litextSelectors = Set([
            "copyMenuItemTapped",
            "selectAllTapped",
            "shareMenuItemTapped"
        ])
        return items.contains { litextSelectors.contains(NSStringFromSelector($0.action)) }
    }

    static func augmentedMenuItems(from items: [UIMenuItem]?) -> [UIMenuItem] {
        let existing = items ?? []
        var seen = Set(existing.map { NSStringFromSelector($0.action) })

        let customItems = EnhancedTextSelectionAction.allCases.compactMap { action -> UIMenuItem? in
            let selectorName = NSStringFromSelector(action.selector)
            guard !seen.contains(selectorName) else { return nil }
            seen.insert(selectorName)
            return UIMenuItem(title: action.title, action: action.selector)
        }

        guard !customItems.isEmpty else { return existing }
        return [customItems[0]] + existing + Array(customItems.dropFirst())
    }

    static func post(_ action: EnhancedTextSelectionAction, text: String) {
        NotificationCenter.default.post(
            name: textSelectionActionNotificationName,
            object: nil,
            userInfo: [
                "action": action.rawValue,
                "text": text
            ]
        )
    }

    private static func swizzle(cls: AnyClass, original: Selector, replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else {
            return
        }

        let replacementImplementation = method_getImplementation(replacementMethod)
        let replacementTypes = method_getTypeEncoding(replacementMethod)
        let didAddMethod = class_addMethod(cls, original, replacementImplementation, replacementTypes)

        if didAddMethod {
            class_replaceMethod(
                cls,
                replacement,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }
}

fileprivate extension LTXLabel {
    func iexa_performSelectionAction(_ action: EnhancedTextSelectionAction) {
        guard let text = EnhancedTextSelectionMenu.selectedText(from: self) else { return }
        UIMenuController.shared.setMenuVisible(false, animated: true)
        clearSelection()
        EnhancedTextSelectionMenu.post(action, text: text)
    }

    @objc func iexaAskSelectedText(_ sender: Any?) {
        iexa_performSelectionAction(.ask)
    }

    @objc func iexaSearchSelectedTextOnWeb(_ sender: Any?) {
        iexa_performSelectionAction(.searchWeb)
    }

    @objc func iexaLookUpSelectedText(_ sender: Any?) {
        guard let text = EnhancedTextSelectionMenu.selectedText(from: self) else { return }
        UIMenuController.shared.setMenuVisible(false, animated: true)

        #if !targetEnvironment(macCatalyst)
        if UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: text),
           let presenter = iexa_parentViewController {
            clearSelection()
            DispatchQueue.main.async {
                let lookup = UIReferenceLibraryViewController(term: text)
                presenter.present(lookup, animated: true)
            }
            return
        }
        #endif

        clearSelection()
        EnhancedTextSelectionMenu.post(.searchWeb, text: text)
    }

    @objc func iexa_canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if EnhancedTextSelectionMenu.isEnhancedAction(action) {
            return EnhancedTextSelectionMenu.selectedText(from: self) != nil
        }
        return iexa_canPerformAction(action, withSender: sender)
    }
}

fileprivate extension UIMenuController {
    @objc func iexa_setMenuItems(_ menuItems: [UIMenuItem]?) {
        guard EnhancedTextSelectionMenu.shouldAugmentMenuItems(menuItems) else {
            iexa_setMenuItems(menuItems)
            return
        }
        iexa_setMenuItems(EnhancedTextSelectionMenu.augmentedMenuItems(from: menuItems))
    }

    @objc func iexa_showMenu(from targetView: UIView, rect targetRect: CGRect) {
        if targetView is LTXLabel {
            EnhancedTextSelectionMenu.augmentCurrentMenu()
        }
        iexa_showMenu(from: targetView, rect: targetRect)
    }
}

fileprivate extension UIResponder {
    var iexa_parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

#endif
