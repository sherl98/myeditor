import {
  realmPlugin,
  createRootEditorSubscription$,
  createActiveEditorSubscription$,
  historyState$,
} from '@mdxeditor/editor'
import { CAN_UNDO_COMMAND, CAN_REDO_COMMAND, COMMAND_PRIORITY_LOW } from 'lexical'

export const runtime = {
  sessionID: '',
  revision: 0,
  sequence: 0,
  source: '',
  original: '',
  outline: [],
  loaded: false,
  programmatic: false,
  composing: false,
  readOnly: true,
  editor: null,
  activeEditor: null,
  history: null,
  canUndo: false,
  canRedo: false,
  fallback: false,
}

export function post(type, data = {}) {
  window.webkit?.messageHandlers?.myEditor?.postMessage({
    type,
    sessionID: runtime.sessionID,
    revision: runtime.revision,
    ...data,
  })
}

export function postHistory() {
  post('history', { canUndo: runtime.canUndo, canRedo: runtime.canRedo })
}

export const engineBridgePlugin = realmPlugin({
  init(realm) {
    realm.pub(createRootEditorSubscription$, (editor) => {
      runtime.editor = editor
      runtime.history = realm.getValue(historyState$)
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
