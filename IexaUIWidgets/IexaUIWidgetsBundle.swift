//
//  IexaUIWidgetsBundle.swift
//  IexaUIWidgets
//

import WidgetKit
import SwiftUI

@main
struct IexaUIWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // Home screen widget — single resizable widget (drag to switch small ↔ medium)
        QuickActionsWidget()

        // Lock screen accessories
        LockScreenWidget()          // accessoryCircular / accessoryRectangular / accessoryInline

        // Live Activity / Dynamic Island for active Iexa runs
        IexaRunLiveActivityWidget()

        // Control Center (iOS 18+)
        IexaUIWidgetsControl()
    }
}
