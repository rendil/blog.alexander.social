#!/bin/bash
ENV=production hugo && mc mirror --overwrite --remove ./public minio/blog.alexander.social
