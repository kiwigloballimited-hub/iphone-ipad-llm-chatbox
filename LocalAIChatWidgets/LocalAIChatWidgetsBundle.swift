import SwiftUI
import WidgetKit

@main
struct LocalAIChatWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickAskWidget()
        GenerationLiveActivity()
    }
}
