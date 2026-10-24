FROM swift:6.1.3-noble AS build
WORKDIR /src
COPY Engine/Package.swift Engine/Package.swift
COPY Engine/Sources Engine/Sources
COPY Engine/Tests Engine/Tests
COPY Telegram/Package.swift Telegram/Package.swift
COPY Telegram/Sources Telegram/Sources
COPY Telegram/Tests Telegram/Tests
COPY Shared Shared
RUN swift test --package-path Engine && swift test --package-path Telegram && \
    swift build --package-path Telegram -c release --static-swift-stdlib && \
    mkdir /out && cp $(swift build --package-path Telegram -c release --show-bin-path)/fxclip-telegram /out/

FROM swift:6.1.3-slim
RUN groupadd --gid 10001 fxclip && useradd --uid 10001 --gid 10001 fxclip && \
    mkdir /data && chown fxclip:fxclip /data
COPY --from=build /out/fxclip-telegram /app/fxclip-telegram
COPY Shared/rules.json /app/rules.json
USER 10001:10001
ENV FXCLIP_RULES=/app/rules.json FXCLIP_DATA=/data
ENTRYPOINT ["/app/fxclip-telegram"]
