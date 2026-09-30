import {
  realmPlugin,
  createRootEditorSubscription$,
  createActiveEditorSubscription$,
  historyState$,
} from '@mdxeditor/editor'
import { CAN_UNDO_COMMAND, CAN_REDO_COMMAND, COMMAND_PRIORITY_LOW } from 'lexical'
import { attachEditor } from '../editor/documentSync.js'

// Shared page state. Every field is declared here; modules only mutate it.
export const runtime = {
  // Document identity: native rejects messages from an earlier load.
  sessionID: '',
  revision: 0,
  loadToken: 0,
  // Latest exported Markdown and its sequence number.
  sequence: 0,
  source: '',
  outline: [],
  loaded: false,
  programmatic: false,
  composing: false,
  readOnly: true,
  showsSource: false,
  // Whole-document CodeMirror view for syntax the rich editor cannot load.
  fallback: false,
  validation: false,
  editor: null,
  activeEditor: null,
  history: null,
  historyTarget: null,
  cellDirty: false,
  canUndo: false,
  canRedo: false,
  // Callbacks installed by the App component.
  applyFallback: null,
  updateSourcePreview: null,
  onDocumentDirty: null,
}

export function post(type, data = {}) {
  window.webkit?.messageHandlers?.myEditor?.postMessage({
    type,
    sessionID: runtime.sessionID,
    revision: runtime.revision,
    ...data,
  })
}

let postedHistory = ''
export function postHistory() {
  // Lexical reports undo/redo availability several times per keystroke.
  const state = `${runtime.revision}:${runtime.canUndo}:${runtime.canRedo}`
  if (state === postedHistory) return
  postedHistory = state
  post('history', { canUndo: runtime.canUndo, canRedo: runtime.canRedo })
}

export const engineBridgePlugin = realmPlugin({
  init(realm) {
    realm.pub(createRootEditorSubscription$, (editor) => {
      runtime.editor = editor
      runtime.history = realm.getValue(historyState$)
      const detach = attachEditor(editor, realm, () => runtime.onDocumentDirty?.())
      const undo = editor.registerCommand(
        CAN_UNDO_COMMAND,
        (value) => {
          if (!runtime.fallback && runtime.historyTarget === editor) {
            runtime.canUndo = value
            postHistory()
          }
          return false
        },
        COMMAND_PRIORITY_LOW,
      )
      const redo = editor.registerCommand(
        CAN_REDO_COMMAND,
        (value) => {
          if (!runtime.fallback && runtime.historyTarget === editor) {
            runtime.canRedo = value
            postHistory()
          }
          return false
        },
        COMMAND_PRIORITY_LOW,
      )
      return () => {
        undo()
        redo()
        detach()
        if (runtime.editor === editor) runtime.editor = null
      }
    })
    realm.pub(createActiveEditorSubscription$, (editor) => {
      runtime.activeEditor = editor
      const undo = editor.registerCommand(
        CAN_UNDO_COMMAND,
        (value) => {
          if (!runtime.fallback && (!runtime.historyTarget || runtime.historyTarget === editor)) {
            runtime.canUndo = value
            postHistory()
          }
          return false
        },
        COMMAND_PRIORITY_LOW,
      )
      const redo = editor.registerCommand(
        CAN_REDO_COMMAND,
        (value) => {
          if (!runtime.fallback && (!runtime.historyTarget || runtime.historyTarget === editor)) {
            runtime.canRedo = value
            postHistory()
          }
          return false
        },
        COMMAND_PRIORITY_LOW,
      )
      return () => {
        undo()
        redo()
        if (runtime.activeEditor === editor) runtime.activeEditor = null
      }
    })
  },
})
