import SwiftUI

// MARK: - macOS Dialog Sizing Modifier

struct MacOSDialogModifier: ViewModifier {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
    let minHeight: CGFloat
    let idealHeight: CGFloat  
    let maxHeight: CGFloat
    
    init(
        minWidth: CGFloat = 320,
        idealWidth: CGFloat = 480,
        maxWidth: CGFloat = 800,
        minHeight: CGFloat = 240,
        idealHeight: CGFloat = 360,
        maxHeight: CGFloat = 600
    ) {
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.idealHeight = idealHeight
        self.maxHeight = maxHeight
    }
    
    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .frame(
                minWidth: minWidth,
                idealWidth: idealWidth,
                maxWidth: maxWidth,
                minHeight: minHeight,
                idealHeight: idealHeight,
                maxHeight: maxHeight
            )
            .fixedSize(horizontal: false, vertical: true)
            #endif
    }
}

// MARK: - View Extension

extension View {
    /// Applies macOS-appropriate dialog sizing constraints
    /// - Parameters:
    ///   - minWidth: Minimum width (default: 320)
    ///   - idealWidth: Ideal width (default: 480)  
    ///   - maxWidth: Maximum width (default: 800)
    ///   - minHeight: Minimum height (default: 240)
    ///   - idealHeight: Ideal height (default: 360)
    ///   - maxHeight: Maximum height (default: 600)
    /// - Returns: Modified view with appropriate macOS sizing
    func macOSDialog(
        minWidth: CGFloat = 320,
        idealWidth: CGFloat = 480,
        maxWidth: CGFloat = 800,
        minHeight: CGFloat = 240,
        idealHeight: CGFloat = 360,
        maxHeight: CGFloat = 600
    ) -> some View {
        modifier(MacOSDialogModifier(
            minWidth: minWidth,
            idealWidth: idealWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            idealHeight: idealHeight,
            maxHeight: maxHeight
        ))
    }
    
    /// Applies compact macOS dialog sizing for smaller dialogs like AddURL
    func compactMacOSDialog() -> some View {
        macOSDialog(
            minWidth: 280,
            idealWidth: 400,
            maxWidth: 600,
            minHeight: 180,
            idealHeight: 250,
            maxHeight: 400
        )
    }
    
    /// Applies settings dialog sizing for larger configuration dialogs
    func settingsMacOSDialog() -> some View {
        macOSDialog(
            minWidth: 450,
            idealWidth: 600,
            maxWidth: 900,
            minHeight: 400,
            idealHeight: 600,
            maxHeight: 800
        )
    }
    
    /// Applies macOS dialog sizing specifically for scrollable content
    func scrollableMacOSDialog(
        minWidth: CGFloat = 450,
        idealWidth: CGFloat = 600,
        maxWidth: CGFloat = 900,
        minHeight: CGFloat = 400,
        idealHeight: CGFloat = 600,
        maxHeight: CGFloat = 800
    ) -> some View {
        #if os(macOS)
        self.frame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            idealHeight: idealHeight,
            maxHeight: maxHeight
        )
        // Don't use fixedSize for scrollable content
        #else
        self
        #endif
    }
}

// MARK: - Flexible Picker Modifier

struct FlexiblePickerModifier: ViewModifier {
    let minWidth: CGFloat?
    let idealWidth: CGFloat?
    
    init(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil) {
        self.minWidth = minWidth
        self.idealWidth = idealWidth
    }
    
    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .frame(
                minWidth: minWidth,
                idealWidth: idealWidth
            )
            .fixedSize(horizontal: false, vertical: true)
            #endif
    }
}

extension View {
    /// Makes picker controls flexible on macOS instead of using fixed widths
    /// - Parameters:
    ///   - minWidth: Optional minimum width
    ///   - idealWidth: Optional ideal width
    /// - Returns: Modified view with flexible picker sizing
    func flexiblePicker(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil) -> some View {
        modifier(FlexiblePickerModifier(minWidth: minWidth, idealWidth: idealWidth))
    }
}