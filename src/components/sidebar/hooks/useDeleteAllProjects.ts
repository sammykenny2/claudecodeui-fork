import { useCallback, useState } from 'react';
import { api } from '../../../utils/api';
import type { Project } from '../../../types/app';

export function useDeleteAllProjects(
  projects: Project[],
  onProjectDelete?: (projectName: string) => void,
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
          const response = await api.deleteProject(project.name, true);
          if (response.ok) {
            onProjectDelete?.(project.name);
          }
        } catch (error) {
          console.error(`[DeleteAll] Error deleting project ${project.name}:`, error);
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
