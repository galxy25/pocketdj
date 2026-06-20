// Transient app banner (toast). Driven by useRipsStore.notice, which auto-clears after
// 5s (set via notify()). Tap to dismiss early. Used e.g. for the rip-server version
// handshake ("outdated — restart it for live streaming").
import { useRipsStore } from '../../store/useRipsStore';

export function Banner() {
  const notice = useRipsStore((s) => s.notice);
  if (!notice) return null;
  return (
    <div
      className={`pdj-banner pdj-banner--${notice.kind}`}
      role="status"
      data-testid="app-banner"
      onClick={() => useRipsStore.setState({ notice: null })}
    >
      {notice.text}
    </div>
  );
}
