// Renders a cover-art thumbnail from an art cache key via the shared, ref-counted
// art-URL cache (useArtUrl). Falls back to a styled placeholder.
import { useArtUrl } from './useArtUrl';

interface Props {
  artKey?: string;
  alt: string;
  size?: number;
  className?: string;
}

export function Thumbnail({ artKey, alt, size = 56, className }: Props) {
  const url = useArtUrl(artKey);

  return (
    <div
      className={'pdj-thumb' + (className ? ' ' + className : '')}
      style={{ width: size, height: size }}
      aria-label={alt}
    >
      {url ? (
        <img src={url} alt={alt} width={size} height={size} loading="lazy" />
      ) : (
        <span className="pdj-thumb__ph" aria-hidden>
          ♪
        </span>
      )}
    </div>
  );
}
