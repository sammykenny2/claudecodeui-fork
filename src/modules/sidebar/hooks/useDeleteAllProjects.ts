import { useCallback, useState } from 'react';

import { api } from '@/shared/api';
import type { Project } from '@/shared/types';

export function useDeleteAllProjects(
  projects: Project[],
  onProjectDelete?: (projectId: string) => void,
) {
  const [showConfirmation, setShowConfirmation] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  const requestDeleteAll = useCallback(() => {
    if (projects.length === 0) return;
    setShowConfirmation(true);
  }, [projects.length]);

  const cancelDeleteAll = useCallback(() => {
    if (isDeleting) return;
    setShowConfirmation(false);
  }, [isDeleting]);

  const confirmDeleteAll = useCallback(async () => {
    setIsDeleting(true);
    try {
      for (const project of projects) {
        try {
          const response = await api.deleteProject(project.projectId, true);
          if (response.ok) {
            onProjectDelete?.(project.projectId);
          }
        } catch (error) {
          console.error(`[DeleteAll] Error deleting project ${project.projectId}:`, error);
        }
      }
    } finally {
      setIsDeleting(false);
      setShowConfirmation(false);
    }
  }, [projects, onProjectDelete]);

  return {
    showDeleteAllConfirmation: showConfirmation,
    isDeletingAll: isDeleting,
    requestDeleteAll,
    cancelDeleteAll,
    confirmDeleteAll,
  };
}
