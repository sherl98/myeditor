import AppKit
import SwiftUI

struct ReaderCommands: Commands {
    let application: ApplicationController
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开文档…", action: application.openPicker).keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存", action: application.saveActive)
                .keyboardShortcut("s")
                .disabled(
                    application.activeSession == nil
                        || application.activeSession?.isComposing == true)
            Button("另存为…") {
                if let session = application.activeSession {
                    Task { await application.saveCopy(session) }
                }
            }.keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(application.activeSession == nil)
            Divider()
            Button(application.activeSession == nil ? "关闭窗口" : "关闭文档") {
                application.closeKeyWindow()
            }.keyboardShortcut("w")
                .disabled(application.isQuitting)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销", action: application.undo).keyboardShortcut("z").disabled(
                !application.canUndo)
            Button("重做", action: application.redo).keyboardShortcut(
                "z", modifiers: [.command, .shift]
            ).disabled(!application.canRedo)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("查找…") { application.focusSearch() }.keyboardShortcut("f")
                .disabled(application.activeSession == nil)
            Button("查找并替换…") { application.focusSearch(replace: true) }.keyboardShortcut(
                "f", modifiers: [.command, .option]
            )
            .disabled(application.activeSession == nil)
            Button("查找下一处") {
                if let session = application.activeSession { application.findNext(session, by: 1) }
            }.keyboardShortcut("g")
                .disabled(application.activeSession == nil)
            Button("查找上一处") {
                if let session = application.activeSession { application.findNext(session, by: -1) }
            }.keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(application.activeSession == nil)
        }
        CommandMenu("阅读") {
            Button(application.activeSession?.isEditing == true ? "完成" : "编辑") {
                if let session = application.activeSession { application.toggleEditing(session) }
            }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(
                application.activeSession == nil)
            Divider()
            Button("上一章") {
                if let s = application.activeSession { application.navigateRelative(s, by: -1) }
            }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(
                    application.activeSession == nil
                        || application.activeSession?.activePrimaryID
                            == application.activeSession?.primaryHeadings.first?.id
                )
            Button("下一章") {
                if let s = application.activeSession { application.navigateRelative(s, by: 1) }
            }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(
                    application.activeSession == nil
                        || application.activeSession?.activePrimaryID
                            == application.activeSession?.primaryHeadings.last?.id
                )
            Divider()
            Button("放大文字") { application.preferences.changeFont(by: 10) }.keyboardShortcut("+")
                .disabled(application.preferences.fontPercent >= 140)
            Button("缩小文字") { application.preferences.changeFont(by: -10) }.keyboardShortcut("-")
                .disabled(application.preferences.fontPercent <= 80)
            Button("实际字号") { application.preferences.fontPercent = 100 }.keyboardShortcut("0")
        }
    }
}
