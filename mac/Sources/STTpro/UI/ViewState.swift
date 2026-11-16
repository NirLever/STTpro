import SwiftUI

/// Drop-in replacement for `@State`.
///
/// In current SDKs `@State` is a macro whose compiler plugin ships with full
/// Xcode but not with the Command Line Tools, so `swift build` fails without
/// Xcode. This wrapper stores the value in a `@StateObject` box instead (no
/// macro needed) and behaves the same for our views.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}
