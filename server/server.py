"""
Serveur de transcription audio Whisper
Lancer avec : uvicorn server:app --host 0.0.0.0 --port 8000
"""

import os
import tempfile
import logging
import whisper
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

app = FastAPI(title="Whisper Transcription Server")

# Autorise les requêtes depuis l'app Flutter (réseau local)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

# Charger le modèle au démarrage (une seule fois)
# Modèles disponibles : tiny, base, small, medium, large
# small = bon compromis vitesse/précision pour le français
MODEL_NAME = os.getenv("WHISPER_MODEL", "small")
logger.info(f"Chargement du modèle Whisper '{MODEL_NAME}'...")
model = whisper.load_model(MODEL_NAME)
logger.info("Modèle prêt.")


@app.get("/health")
async def health():
    """Endpoint de vérification — utile pour tester la connexion depuis l'app."""
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    """
    Reçoit un fichier audio (WAV, M4A, MP3…) et retourne le texte transcrit.
    Réponse : { "text": "...", "language": "fr" }
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="Aucun fichier reçu.")

    # Lire le fichier en mémoire
    content = await file.read()
    if len(content) == 0:
        raise HTTPException(status_code=400, detail="Fichier audio vide.")

    logger.info(f"Transcription de '{file.filename}' ({len(content) // 1024} Ko)...")

    # Sauvegarder dans un fichier temporaire (Whisper a besoin d'un chemin)
    suffix = os.path.splitext(file.filename or ".wav")[1] or ".wav"
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(content)
            tmp_path = tmp.name

        result = model.transcribe(
            tmp_path,
            language="fr",
            fp16=False,          # fp16=False requis si pas de GPU NVIDIA
            task="transcribe",
        )

        text = result["text"].strip()
        detected_lang = result.get("language", "fr")
        logger.info(f"Résultat ({detected_lang}) : {text[:120]}")

        return {"text": text, "language": detected_lang}

    except Exception as e:
        logger.error(f"Erreur transcription : {e}")
        raise HTTPException(status_code=500, detail=f"Erreur Whisper : {str(e)}")
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)
