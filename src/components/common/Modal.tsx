// Minimal accessible modal. Closes on backdrop click + Escape.
import { useEffect, type ReactNode } from 'react';

interface Props {
  open: boolean;
  onClose: () => void;
  title: string;
  testId?: string;
  children: ReactNode;
}

export function Modal({ open, onClose, title, testId, children }: Props) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  if (!open) return null;
  return (
    <div className="pdj-modal__backdrop" onClick={onClose}>
      <div
        className="pdj-modal"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        data-testid={testId}
        onClick={(e) => e.stopPropagation()}
      >
        <header className="pdj-modal__header">
          <h2>{title}</h2>
          <button className="pdj-iconbtn" onClick={onClose} aria-label="Close">
            ✕
          </button>
        </header>
        <div className="pdj-modal__body">{children}</div>
      </div>
    </div>
  );
}
