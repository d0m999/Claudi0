import SwiftUI

extension View {
    /// Keep native menu controls neutral even inside an accent-tinted presentation.
    package func nativeMenuControl() -> some View {
        pickerStyle(.menu)
            .tint(nil)
    }
}
