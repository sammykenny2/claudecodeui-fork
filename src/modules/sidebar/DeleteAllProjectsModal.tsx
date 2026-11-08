import ReactDOM from 'react-dom';
import { AlertTriangle, Loader2, Trash2 } from 'lucide-react';

import { Button } from '@/shared/ui';

type DeleteAllProjectsModalProps = {
  projectCount: number;
  isDeleting: boolean;
  onCancel: () => void;
  onConfirm: () => void;
};

export default function DeleteAllProjectsModal({
  projectCount,
  isDeleting,
  onCancel,
  onConfirm,
}: DeleteAllProjectsModalProps) {
  return ReactDOM.createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm">
      <div className="w-full max-w-md overflow-hidden rounded-xl border border-border bg-card shadow-2xl">
        <div className="p-6">
          <div className="flex items-start gap-4">
            <div className="flex h-12 w-12 flex-shrink-0 items-center justify-center rounded-full bg-red-100 dark:bg-red-900/30">
              <AlertTriangle className="h-6 w-6 text-red-600 dark:text-red-400" />
            </div>
            <div className="min-w-0 flex-1">
              <h3 className="mb-2 text-lg font-semibold text-foreground">
                Delete All Projects
              </h3>
              <div className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 dark:border-red-800 dark:bg-red-900/20">
                <p className="text-sm font-medium text-red-700 dark:text-red-300">
                  This will delete all {projectCount} projects and their conversations.
                </p>
                <p className="mt-1 text-xs text-red-600 dark:text-red-400">
                  All conversations will be permanently deleted.
                </p>
              </div>
              <p className="mt-3 text-xs text-muted-foreground">
                This action cannot be undone.
              </p>
            </div>
          </div>
        </div>
        <div className="flex gap-3 border-t border-border bg-muted/30 p-4">
          <Button variant="outline" className="flex-1" onClick={onCancel} disabled={isDeleting}>
            Cancel
          </Button>
          <Button
            variant="destructive"
            className="flex-1 bg-red-600 text-white hover:bg-red-700"
            onClick={onConfirm}
            disabled={isDeleting}
          >
            {isDeleting ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <Trash2 className="mr-2 h-4 w-4" />
            )}
            {isDeleting ? 'Deleting...' : 'Delete All'}
          </Button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
