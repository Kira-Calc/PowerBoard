import AppKit
import ElectricityCore
import ElectricityReceipt
import SwiftUI

/// Which export menu item opened the receipt sheet; it decides the default button (appendix R2.1).
enum ReceiptSheetPurpose: String, Identifiable {
    case image
    case print

    var id: String { rawValue }
}

/// Receipt preview and options (appendix R2.2): the receipt at its real proportions on the left, options on the
/// right, then copy, save and print.
struct ReceiptSheet: View {
    let report: Report
    let context: DashboardContext
    let purpose: ReceiptSheetPurpose

    @Environment(\.dismiss) private var dismiss
    @State private var paper = ReceiptSettings.defaultPaper
    @AppStorage(ReceiptSettings.paperEffectKey) private var paperEffect = true
    @AppStorage(ReceiptSettings.showsQRCodeKey) private var showsQRCode = true
    @AppStorage(ReceiptSettings.customerKey) private var customer = ""
    @State private var monochrome = false
    /// One serial and print time per opened sheet, so the preview and the output match. The serial is used up only
    /// when the receipt goes out.
    @State private var serial = ReceiptSettings.nextSerial()
    @State private var printedAt = Date()
    @State private var preview: CGImage?
    @State private var message: LocalizedStringKey?
    @State private var errorText: String?

    /// Preview width on screen; the receipt keeps its proportions inside it.
    private static let previewWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("receipt.title").font(.headline)
            HStack(alignment: .top, spacing: 20) {
                previewPane
                options
            }
            footer
        }
        .padding(20)
        .frame(width: 700, height: 620)
        .task(id: renderKey) { renderPreview() }
    }

    // MARK: Parts

    private var previewPane: some View {
        ScrollView {
            Group {
                if let preview {
                    Image(decorative: preview, scale: 2)
                        .resizable()
                        .interpolation(monochrome ? .none : .high)
                        .scaledToFit()
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .frame(width: Self.previewWidth)
            .padding(.vertical, 8)
        }
        .frame(width: Self.previewWidth + 24)
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(Text("receipt.preview"))
    }

    private var options: some View {
        Form {
            LabeledContent("receipt.period") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ReportStrings.app.title(report))
                    Text("receipt.period.note").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("receipt.paper", selection: $paper) {
                Text(verbatim: "80 mm").tag(ReceiptPaper.mm80)
                Text(verbatim: "58 mm").tag(ReceiptPaper.mm58)
            }
            .pickerStyle(.segmented)
            Toggle("receipt.paperEffect", isOn: $paperEffect)
            Toggle("receipt.qrCode", isOn: $showsQRCode)
            Toggle("receipt.monochrome", isOn: $monochrome)
            TextField("receipt.customer", text: $customer, prompt: Text("receipt.customer.prompt"))
                .onChange(of: customer) { _, value in
                    if value.count > ReceiptModel.maxCustomerLength { customer = String(value.prefix(ReceiptModel.maxCustomerLength)) }
                }
            Text("receipt.projectsNote")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.columns)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            if let errorText {
                Text(verbatim: errorText).font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("receipt.done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("receipt.copy", action: copy)
            if purpose == .image {
                Button("receipt.save", action: save).keyboardShortcut(.defaultAction)
                printButton
            } else {
                Button("receipt.save", action: save)
                printButton.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var printButton: some View {
        Button("receipt.print", action: printReceipt)
            .disabled(ReceiptSettings.printMethod == .none)
            .help(ReceiptSettings.printMethod == .none ? Text("receipt.print.off") : Text(verbatim: ""))
    }

    // MARK: Rendering

    private var model: ReceiptModel {
        let enabled = Set(context.settings.enabledEquivalents(from: context.model.equivalents).map(\.id))
        return ReceiptModel(report: report, equivalents: context.model.equivalents, enabledEquivalentIDs: enabled,
                            language: ReceiptSettings.language, serialNumber: serial,
                            customer: customer, showsQRCode: showsQRCode, printedAt: printedAt)
    }

    private var renderKey: [AnyHashable] { [paper, paperEffect, showsQRCode, customer, monochrome] }

    /// The PNG look, or with "preview as printed" the 1-bit image the printer gets, scaled to the same size.
    private func renderPreview() {
        if monochrome {
            preview = ReceiptRenderer.printBitmap(model: model, paper: paper, logo: ReceiptSettings.logo)?.cgImage()
                .flatMap { Self.upscaled($0) }
        } else {
            preview = ReceiptRenderer.image(model: model, paper: paper, logo: ReceiptSettings.logo, paperEffect: paperEffect, scale: 2)
        }
    }

    /// Doubles a 1-dot-per-pixel image without smoothing, so it shows at the scale of the 2x PNG.
    private static func upscaled(_ image: CGImage) -> CGImage? {
        let width = image.width * 2, height = image.height * 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func png() -> Data? {
        do {
            errorText = nil
            return try ReceiptRenderer.png(model: model, paper: paper, logo: ReceiptSettings.logo, paperEffect: paperEffect)
        } catch {
            errorText = String(format: String(localized: "receipt.error"), error.localizedDescription)
            return nil
        }
    }

    // MARK: Actions

    private func copy() {
        guard let data = png() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        ReceiptSettings.useSerial(serial, now: printedAt)
        message = "receipt.copied"
    }

    private func save() {
        guard let data = png() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReceiptSettings.fileName(report)
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            ReceiptSettings.useSerial(serial, now: printedAt)
            message = "receipt.saved"
        } catch {
            errorText = String(format: String(localized: "receipt.error"), error.localizedDescription)
        }
    }

    private func printReceipt() {
        guard let bitmap = ReceiptRenderer.printBitmap(model: model, paper: paper, logo: ReceiptSettings.logo) else {
            errorText = String(format: String(localized: "receipt.error"), "")
            return
        }
        errorText = nil
        ReceiptSettings.useSerial(serial, now: printedAt)
        ReceiptSystemPrint.run(bitmap, paper: paper, window: NSApp.keyWindow)
    }
}

/// Receipt preferences, shown on the Reports page next to automatic export (appendix R2.3).
struct ReceiptSettingsCard: View {
    @AppStorage(ReceiptSettings.paperKey) private var paper: ReceiptPaper = .mm80
    @AppStorage(ReceiptSettings.printMethodKey) private var printMethod: ReceiptPrintMethod = .system

    var body: some View {
        Card {
            CardHeader(icon: Icons.receipt, color: Palette.neutral, title: "receipt.settings.title")
            Form {
                Picker("receipt.settings.paper", selection: $paper) {
                    Text(verbatim: "80 mm").tag(ReceiptPaper.mm80)
                    Text(verbatim: "58 mm").tag(ReceiptPaper.mm58)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("receipt.settings.printMethod", selection: $printMethod) {
                    Text("receipt.printMethod.system").tag(ReceiptPrintMethod.system)
                    Text("receipt.printMethod.none").tag(ReceiptPrintMethod.none)
                }
                .fixedSize()
            }
            .formStyle(.columns)
        }
    }
}
