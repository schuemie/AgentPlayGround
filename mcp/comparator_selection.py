import os
import httpx
from typing import Optional
from mcp.server.fastmcp import FastMCP

# Initialize the MCP Server
mcp = FastMCP("ComparatorSelectionExplorer")

# Define the base URL (configurable via environment variable)
API_BASE_URL = os.getenv("API_BASE_URL", "http://localhost:8000").rstrip("/")

@mcp.tool()
def check_api_health() -> dict:
    """Health check for the Comparator Selection API."""
    url = f"{API_BASE_URL}/api/health"
    response = httpx.get(url)
    response.raise_for_status()
    return {"status": response.status_code, "data": response.text}

@mcp.tool()
def list_databases() -> dict:
    """List available data sources"""
    url = f"{API_BASE_URL}/api/databases"
    response = httpx.get(url, timeout=30.0)
    response.raise_for_status()
    return response.json()

@mcp.tool()
def search_cohorts(q: str = "", tag: str = "") -> dict:
    """
    Search exposure cohorts by name, optionally filtered by tag.
    
    Args:
        q: Search string to match against cohort name (case-insensitive). Default returns all.
        tag: Optional. Filter cohorts by tag ("RxNorm" for drug ingredients, "ATC" for drug classes).
    """
    url = f"{API_BASE_URL}/api/cohorts"
    params = {"q": q, "tag": tag}
    response = httpx.get(url, params=params, timeout=30.0)
    response.raise_for_status()
    return response.json()

@mcp.tool()
def get_comparator_rankings(
    id: float, 
    database_ids: str = "", 
    min_databases: float = 2.0, 
    comparator_type: str = "", 
    weight_demo: float = 20.0, 
    weight_pres: float = 20.0, 
    weight_hist: float = 20.0, 
    weight_meds: float = 20.0, 
    weight_visit: float = 20.0
) -> dict:
    """
    Get active comparator rankings for a target cohort.

    Returns a ranked list of comparator cohorts based on similarity across multiple domains (demographics, presentation, medical history, prior medications, and visit context).
    Returns the average similarity score across all databases and the number of databases each comparator appears in.
    
    Args:
        id: Target exposure cohort definition ID.
        database_ids: (Optional) Comma-separated list of database IDs to include.
        min_databases: Minimum number of databases a comparator must appear in.
        comparator_type: Filter by type ("ATC", "RxNorm", or "" for both).
        weight_demo: Weight for Demographics domain (0-100).
        weight_pres: Weight for Presentation domain (0-100).
        weight_hist: Weight for Medical history domain (0-100).
        weight_meds: Weight for Prior meds domain (0-100).
        weight_visit: Weight for Visit context domain (0-100).
    """
    url = f"{API_BASE_URL}/api/cohorts/{id}/rankings"
    params = {
        "database_ids": database_ids,
        "min_databases": min_databases,
        "comparator_type": comparator_type,
        "weight_demo": weight_demo,
        "weight_pres": weight_pres,
        "weight_hist": weight_hist,
        "weight_meds": weight_meds,
        "weight_visit": weight_visit
    }
    response = httpx.get(url, params=params, timeout=60.0) 
    response.raise_for_status()
    return response.json()

@mcp.tool()
def compare_cohorts(id1: float, id2: float, database_id: str = "") -> dict:
    """
    Compare two cohorts in a specific database (per-domain similarity).
    
    Args:
        id1: First cohort definition ID (target).
        id2: Second cohort definition ID (comparator).
        database_id: Database ID to compare within. If omitted, the first available is used.
    """
    url = f"{API_BASE_URL}/api/cohorts/{id1}/compare/{id2}"
    params = {"database_id": database_id}
    response = httpx.get(url, params=params, timeout=30.0)
    response.raise_for_status()
    return response.json()

if __name__ == "__main__":
    mcp.run()
