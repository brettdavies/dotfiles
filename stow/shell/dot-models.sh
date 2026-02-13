# Central AI model cache directory
# This file configures environment variables for AI/ML model storage locations
# All models are stored under a central MODELS_HOME directory for easy management

# Central AI model cache directory
export MODELS_HOME="$HOME/models"

# Create the models directory if it doesn't exist
[ ! -d "$MODELS_HOME" ] && mkdir -p "$MODELS_HOME"

# ============================================================================
# Model Storage Locations
# ============================================================================

# HuggingFace models
export HF_HOME="$MODELS_HOME/huggingface"
export HUGGINGFACE_HUB_CACHE="$MODELS_HOME/huggingface/hub"
export TRANSFORMERS_CACHE="$MODELS_HOME/huggingface/transformers"

# PyTorch models
export TORCH_HOME="$MODELS_HOME/torch"

# Ollama models
export OLLAMA_MODELS="$MODELS_HOME/ollama"

# Stable Diffusion / Diffusers
export DIFFUSERS_CACHE="$MODELS_HOME/diffusers"

# TensorFlow Hub models
export TFHUB_CACHE_DIR="$MODELS_HOME/tensorflow-hub"

# spaCy models
export SPACY_DATA="$MODELS_HOME/spacy"

# NLTK data
export NLTK_DATA="$MODELS_HOME/nltk"

# Keras models and data
export KERAS_HOME="$MODELS_HOME/keras"

# MLX and mlx-lm cache
# Note: MLX and mlx-lm use Hugging Face's cache system for model storage
# Models are downloaded and cached via HF_HOME/HUGGINGFACE_HUB_CACHE (configured above)
# MLX doesn't have separate cache environment variables; it uses HuggingFace's infrastructure

# ============================================================================
# Create Model Directories
# ============================================================================

# HuggingFace directories
[ ! -d "$HF_HOME" ] && mkdir -p "$HF_HOME"
[ ! -d "$HUGGINGFACE_HUB_CACHE" ] && mkdir -p "$HUGGINGFACE_HUB_CACHE"
[ ! -d "$TRANSFORMERS_CACHE" ] && mkdir -p "$TRANSFORMERS_CACHE"

# PyTorch directory
[ ! -d "$TORCH_HOME" ] && mkdir -p "$TORCH_HOME"

# Ollama directory
[ ! -d "$OLLAMA_MODELS" ] && mkdir -p "$OLLAMA_MODELS"

# Stable Diffusion / Diffusers directory
[ ! -d "$DIFFUSERS_CACHE" ] && mkdir -p "$DIFFUSERS_CACHE"

# TensorFlow Hub directory
[ ! -d "$TFHUB_CACHE_DIR" ] && mkdir -p "$TFHUB_CACHE_DIR"

# spaCy directory
[ ! -d "$SPACY_DATA" ] && mkdir -p "$SPACY_DATA"

# NLTK directory
[ ! -d "$NLTK_DATA" ] && mkdir -p "$NLTK_DATA"

# Keras directory
[ ! -d "$KERAS_HOME" ] && mkdir -p "$KERAS_HOME"
