import ReactDOM from 'react-dom';
import { AlertTriangle, Trash2, Loader2 } from 'lucide-react';
import { Button } from '../../../../shared/view/ui';

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
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50 p-4">
      <div className="bg-card border border-border rounded-xl shadow-2xl max-w-md w-full overflow-hidden">
        <div className="p-6">
          <div className="flex items-start gap-4">
            <div className="w-12 h-12 rounded-full bg-red-100 dark:bg-red-900/30 flex items-center justify-center flex-shrink-0">
              <AlertTriangle className="w-6 h-6 text-red-600 dark:text-red-400" />
            </div>
            <div className="flex-1 min-w-0">
              <h3 className="text-lg font-semibold text-foreground mb-2">
                Delete All Projects
              </h3>
              <div className="mt-3 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
                <p className="text-sm text-red-700 dark:text-red-300 font-medium">
                  This will delete all {projectCount} projects and their conversations.
                </p>
                <p className="text-xs text-red-600 dark:text-red-400 mt-1">
                  All conversations will be permanently deleted.
                </p>
              </div>
              <p className="text-xs text-muted-foreground mt-3">
                This action cannot be undone.
              </p>
            </div>
          </div>
        </div>
        <div className="flex gap-3 p-4 bg-muted/30 border-t border-border">
          <Button variant="outline" className="flex-1" onClick={onCancel} disabled={isDeleting}>
            Cancel
          </Button>
          <Button
            variant="destructive"
            className="flex-1 bg-red-600 hover:bg-red-700 text-white"
            onClick={onConfirm}
            disabled={isDeleting}
          >
            {isDeleting ? (
              <Loader2 className="w-4 h-4 mr-2 animate-spin" />
            ) : (
              <Trash2 className="w-4 h-4 mr-2" />
            )}
            {isDeleting ? 'Deleting...' : 'Delete All'}
          </Button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
