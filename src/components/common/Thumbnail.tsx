// Renders a cover-art thumbnail from an art cache key, resolving the blob to an
// object URL (LRU-managed in artCache). Falls back to a styled placeholder.
import { useEffect, useState } from 'react';
import { artObjectURL } from '../../storage/artCache';

interface Props {
  artKey?: string;
  alt: string;
  size?: number;
  className?: string;
}

export function Thumbnail({ artKey, alt, size = 56, className }: Props) {
  const [url, setUrl] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setUrl(null);
    if (artKey) {
      artObjectURL(artKey).then((u) => {
        if (live) setUrl(u);
      });
    }
    return () => {
      live = false;
    };
  }, [artKey]);

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
