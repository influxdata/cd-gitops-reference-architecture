# ARGs for the FROM target must occur first.
# Allowing a dynamic source image allows developers to quickly build a single image,
# rather than building the full Dockerfile.cd that compiles many commands.
ARG BIN_IMAGE
FROM ${BIN_IMAGE} as bin_image

FROM alpine:3

# Add certificates first, as that may be a common layer with other alpine-based images.
RUN apk add --no-cache ca-certificates

# The cmd will not change, so set it early for better layer caching.
CMD ["/foo-svc"]

# Again, having a dynamic source directory allows simplified local development.
ARG BIN_SRC_DIR=/app-bins
COPY --from=bin_image ${BIN_SRC_DIR}/foo-svc /foo-svc
